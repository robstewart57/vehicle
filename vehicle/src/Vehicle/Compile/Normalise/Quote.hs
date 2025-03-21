module Vehicle.Compile.Normalise.Quote where

import Vehicle.Compile.Error (MonadCompile, runCompileMonadSilently)
import Vehicle.Compile.Prelude
import Vehicle.Expr.DeBruijn
import Vehicle.Expr.Normalisable
import Vehicle.Expr.Normalised

-- | Converts from a normalised representation to an unnormalised representation.
-- Do not call except for logging and debug purposes, very expensive with nested
-- lambdas.
unnormalise :: forall a b. Quote a b => DBLevel -> a -> b
unnormalise level e = runCompileMonadSilently "unquoting" (quote mempty level e)

-----------------------------------------------------------------------------
-- Quoting

-- i.e. converting back to unnormalised expressions

class Quote a b where
  quote :: MonadCompile m => Provenance -> DBLevel -> a -> m b

instance Quote (NormExpr types) (NormalisableExpr types) where
  quote p level = \case
    VUniverse u -> return $ Universe p u
    VMeta m spine -> quoteApp level p (Meta p m) spine
    VFreeVar v spine -> quoteApp level p (FreeVar p v) spine
    VBoundVar v spine -> quoteApp level p (BoundVar p (dbLevelToIndex level v)) spine
    VBuiltin b spine -> quoteApp level p (Builtin p b) (ExplicitArg p <$> spine)
    VPi binder body ->
      Pi p <$> quote p level binder <*> quote p (level + 1) body
    VLam binder env body -> do
      quotedBinder <- quote p level binder
      quotedEnv <- traverse (\(_n, e) -> quote p (level + 1) e) env
      let liftedEnv = BoundVar p 0 : quotedEnv
      let quotedBody = substituteDB 0 (envSubst liftedEnv) body
      -- Here we deliberately avoid using the standard `quote . eval` approach below
      -- on the body of the lambda, in order to avoid the dependency cycles that
      -- prevent us from printing during NBE.
      --
      -- normBody <- runReaderT (eval (liftEnvOverBinder p env) body) mempty
      -- quotedBody <- quote (level + 1) normBody
      return $ Lam mempty quotedBinder quotedBody

instance Quote (NormBinder types) (NormalisableBinder types) where
  quote p level = traverse (quote p level)

instance Quote (NormArg types) (NormalisableArg types) where
  quote p level = traverse (quote p level)

quoteApp :: MonadCompile m => DBLevel -> Provenance -> NormalisableExpr types -> Spine types -> m (NormalisableExpr types)
quoteApp l p fn spine = normAppList p fn <$> traverse (quote p l) spine

envSubst :: BoundCtx (NormalisableExpr types) -> Substitution (NormalisableExpr types)
envSubst env i = case lookupVar env i of
  Just v -> Right v
  Nothing ->
    developerError $
      "Mis-sized environment" <+> pretty (length env) <+> "when quoting variable" <+> pretty i
