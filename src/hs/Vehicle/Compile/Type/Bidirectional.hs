
module Vehicle.Compile.Type.Bidirectional
  ( TCM
  , Inferrable(..)
  ) where

import Prelude hiding (pi)
import Control.Monad (when)
import Control.Monad.Except (MonadError(..))
import Control.Monad.Reader (MonadReader(..))
import Control.Monad.State (MonadState)
import Data.Foldable (foldrM)
import Data.Map qualified as Map
import Data.List.NonEmpty qualified as NonEmpty (toList)
import Data.Monoid (Endo(..), appEndo)
import Data.Text (pack)

import Vehicle.Compile.Prelude
import Vehicle.Compile.Error
import Vehicle.Language.DSL
import Vehicle.Language.Print
import Vehicle.Compile.Type.Meta
import Vehicle.Compile.Type.WeakHeadNormalForm

--------------------------------------------------------------------------------
-- Bidirectional phase of type-checking
--
-- Recurses through the program inserting implicit and instance arguments and
-- gathering the constraints between meta-variables that need to be satisfied.

-------------------------------------------------------------------------------
-- Type-class for things that can be type-checked

class Inferrable a b where
  infer :: TCM m => a -> m b

instance Inferrable UncheckedProg CheckedProg where
  infer p = logCompilerPass "bidirectional pass" $ inferProg p

instance Inferrable UncheckedExpr CheckedExpr where
  infer e = fst <$> inferExpr e

--------------------------------------------------------------------------------
-- The type-checking monad

-- | The type-checking monad
type TCM m =
  ( MonadLogger              m
  , MonadError  CompileError m
  , MonadState  MetaCtx      m
  , MonadReader VariableCtx  m
  )

--------------------------------------------------------------------------------
-- Debug functions

showDeclEntry :: MonadLogger m => Identifier -> m ()
showDeclEntry ident = do
  logDebug MaxDetail ("decl-entry" <+> pretty ident)
  incrCallDepth

showDeclExit :: MonadLogger m => Identifier -> m ()
showDeclExit ident = do
  decrCallDepth
  logDebug MaxDetail ("decl-exit" <+> pretty ident)

showCheckEntry :: MonadLogger m => CheckedExpr -> UncheckedExpr -> m ()
showCheckEntry t e = do
  logDebug MaxDetail ("check-entry" <+> prettyVerbose e <+> "<-" <+> prettyVerbose t)
  incrCallDepth

showCheckExit :: MonadLogger m => CheckedExpr -> m ()
showCheckExit e = do
  decrCallDepth
  logDebug MaxDetail ("check-exit " <+> prettyVerbose e)

showInferEntry :: MonadLogger m => UncheckedExpr -> m ()
showInferEntry e = do
  logDebug MaxDetail ("infer-entry" <+> prettyVerbose e)
  incrCallDepth

showInferExit :: MonadLogger m => (CheckedExpr, CheckedExpr) -> m ()
showInferExit (e, t) = do
  decrCallDepth
  logDebug MaxDetail ("infer-exit " <+> prettyVerbose e <+> "->" <+> prettyVerbose t)

-------------------------------------------------------------------------------
-- Utility functions

assertIsType :: TCM m => Provenance -> CheckedExpr -> m ()
-- This is a bit of a hack to get around having to have a solver for universe
-- levels. As type definitions will always have an annotated Type 0 inserted
-- by delaboration, we can match on it here. Anything else will be unified
-- with type 0.
assertIsType _ (Type _ _) = return ()
assertIsType p t        = do
  _ <- unify p t (Type (inserted (provenanceOf t)) 0)
  return ()

removeBinderName :: CheckedBinder -> CheckedBinder
removeBinderName (Binder ann v _n t) = Binder ann v Nothing t

unify :: TCM m => Provenance -> CheckedExpr -> CheckedExpr -> m CheckedExpr
unify p e1 e2 = do
  ctx <- getVariableCtx
  addUnificationConstraint p ctx e1 e2
  -- TODO calculate the most general unifier
  return e1

freshMeta :: TCM m => Provenance -> m (Meta, CheckedExpr)
freshMeta p = freshMetaWith p =<< getBoundCtx

--------------------------------------------------------------------------------
-- Checking

checkExpr :: TCM m
          => CheckedExpr   -- Type we're checking against
          -> UncheckedExpr -- Expression being type-checked
          -> m CheckedExpr -- Updated expression
checkExpr expectedType expr = do
  showCheckEntry expectedType expr
  res <- case (expectedType, expr) of
    -- If the type is a meta, then we're forced to switch to infer.
    (Meta ann _, _) -> viaInfer ann expectedType expr

    (Pi _ piBinder resultType, Lam ann lamBinder body)
      | visibilityOf piBinder == visibilityOf lamBinder -> do
        checkedLamBinderType <- checkExpr (Type (inserted ann) 0) (typeOf lamBinder)

        -- Unify the result with the type of the pi binder.
        _ <- unify (provenanceOf ann) (typeOf piBinder) checkedLamBinderType

        -- Add bound variable to context
        checkedBody <- addToBoundCtx (nameOf lamBinder) checkedLamBinderType Nothing $ do
          -- Check if the type of the expression matches the expected result type.
          checkExpr resultType body

        let checkedLamBinder = replaceBinderType checkedLamBinderType lamBinder
        return $ Lam ann checkedLamBinder checkedBody

    (Pi _ binder resultType, e) -> do
      let ann = inserted $ provenanceOf binder

      -- Add the binder to the context
      checkedExpr <- addToBoundCtx (nameOf binder) (typeOf binder) Nothing $
        -- Check if the type of the expression matches the expected result type.
        checkExpr resultType (liftFreeDBIndices 1 e)

      -- Create a new binder mirroring the implicit Pi binder expected
      let lamBinder = Binder ann Implicit (nameOf binder) (typeOf binder)

      -- Prepend a new lambda to the expression with the implicit binder
      return $ Lam ann lamBinder checkedExpr

    (_, Lam ann binder _) -> do
      ctx <- getBoundCtx
      let expected = fromDSL ann $ pi (visibilityOf binder) (tHole "a") (const (tHole "b"))
      throwError $ TypeMismatch (provenanceOf ann) ctx expectedType expected

    (_, Hole ann _name) -> do
      -- Replace the hole with meta-variable. Throws away the expected type. Can we use it somehow?
      -- NOTE, different uses of the same hole name will be interpreted as different meta-variables.
      (_, meta) <- freshMeta (provenanceOf ann)
      return meta

    (_, Type     ann _)     -> viaInfer ann expectedType expr
    (_, Meta     ann _)     -> viaInfer ann expectedType expr
    (_, App      ann _ _)   -> viaInfer ann expectedType expr
    (_, Pi       ann _ _)   -> viaInfer ann expectedType expr
    (_, Builtin  ann _)     -> viaInfer ann expectedType expr
    (_, Var      ann _)     -> viaInfer ann expectedType expr
    (_, Let      ann _ _ _) -> viaInfer ann expectedType expr
    (_, Literal  ann _)     -> viaInfer ann expectedType expr
    (_, LSeq     ann _ _)   -> viaInfer ann expectedType expr
    (_, Ann      ann _ _)   -> viaInfer ann expectedType expr
    (_, PrimDict ann _)     -> viaInfer ann expectedType expr

  showCheckExit res
  return res

viaInfer :: TCM m => CheckedAnn -> CheckedExpr -> UncheckedExpr -> m CheckedExpr
viaInfer ann expectedType e = do
  -- Switch to inference mode
  (checkedExpr, actualType) <- inferExpr e
  -- Insert any needed implicit or instance arguments
  (appliedCheckedExpr, resultType) <- inferApp ann checkedExpr actualType []
  -- Assert the expected and the actual types are equal
  _t <- unify (provenanceOf ann) expectedType resultType
  return appliedCheckedExpr

--------------------------------------------------------------------------------
-- Inference

inferProg :: TCM m => UncheckedProg -> m CheckedProg
inferProg (Main ds) = do
  logDebug MaxDetail "Beginning initial type-checking pass"
  result <- Main <$> inferDecls ds
  logDebug MaxDetail "Ending initial type-checking pass\n"
  return result

inferDecls :: TCM m => [UncheckedDecl] -> m [CheckedDecl]
inferDecls [] = return []
inferDecls (d : ds) = do
  let ident = identifierOf d
  showDeclEntry ident

  (checkedDecl, checkedDeclBody, checkedDeclType) <- case d of
    DefResource p r _ t -> do
      (checkedType, typeOfType) <- inferExpr t
      assertIsType p typeOfType
      let checkedDecl = DefResource p r ident checkedType
      return (checkedDecl, Nothing, checkedType)

    DefFunction p usage _ t body -> do
      (checkedType, typeOfType) <- inferExpr t
      assertIsType p typeOfType
      checkedBody <- checkExpr checkedType body
      let checkedDecl = DefFunction p usage ident checkedType checkedBody
      return (checkedDecl, Just checkedBody, checkedType)

  showDeclExit ident
  checkedDecls <- addToDeclCtx ident checkedDeclType checkedDeclBody $ inferDecls ds
  return $ checkedDecl : checkedDecls

-- | Takes in an unchecked expression and attempts to infer it's type.
-- Returns the expression annotated with its type as well as the type itself.
inferExpr :: TCM m
          => UncheckedExpr
          -> m (CheckedExpr, CheckedExpr)
inferExpr e = do
  showInferEntry e
  res <- case e of
    Type ann l ->
      return (e , Type (inserted ann) (l + 1))

    Meta _ m -> compilerDeveloperError $
      "Trying to infer the type of a meta-variable" <+> pretty m

    Hole ann _name -> do
      -- Replace the hole with meta-variable.
      -- NOTE, different uses of the same hole name will be interpreted as different meta-variables.
      (_, exprMeta) <- freshMeta (provenanceOf ann)
      (_, typeMeta) <- freshMeta (provenanceOf ann)
      return (exprMeta, typeMeta)

    Ann ann expr exprType -> do
      (checkedExprType, exprTypeType) <- inferExpr exprType
      _ <- unify (provenanceOf ann) exprTypeType (Type (inserted ann) 0)
      checkedExpr <- checkExpr checkedExprType expr
      return (Ann ann checkedExpr checkedExprType , checkedExprType)

    Pi ann binder resultType -> do
      (checkedBinderType, typeOfBinderType) <- inferExpr (typeOf binder)

      (checkedResultType, typeOfResultType) <-
        addToBoundCtx (nameOf binder) checkedBinderType Nothing $ inferExpr resultType

      let maxResultType = typeOfBinderType `tMax` typeOfResultType
      let checkedBinder = replaceBinderType checkedBinderType binder
      return (Pi ann checkedBinder checkedResultType , maxResultType)

    -- Literals are slightly tricky to type-check, as by default they
    -- probably are standalone, i.e. not wrapped in an `App`, in which
    -- case we need to insert an `App` around them. However, if the
    -- user has provided an implicit argument to them or we are type
    -- checking a second time, then the `App` will already be present.
    -- One approach might be to pass a boolean flag through `infer`
    -- which signals whether the parent node is an `App`, however
    -- for now it's simplier to split into the following two cases:
    App ann (Literal ann' l) args -> do
      let (checkedLit, checkedLitType) = inferLiteral ann' l
      inferApp ann checkedLit checkedLitType (NonEmpty.toList args)

    Literal ann l -> do
      let (checkedLit, checkedLitType) = inferLiteral ann l
      inferApp ann checkedLit checkedLitType []


    App ann fun args -> do
      (checkedFun, checkedFunType) <- inferExpr fun
      inferApp ann checkedFun checkedFunType (NonEmpty.toList args)

    Var ann (Bound i) -> do
      -- Lookup the type of the variable in the context.
      ctx <- getBoundCtx
      case ctx !!? i of
        Just (_, checkedType, _) -> do
          let liftedCheckedType = liftFreeDBIndices (i+1) checkedType
          return (Var ann (Bound i), liftedCheckedType)
        Nothing      -> compilerDeveloperError $
          "DBIndex" <+> pretty i <+> "out of bounds when looking" <+>
          "up variable in context" <+> prettyVerbose (ctxNames ctx) <+> "at" <+> pretty (provenanceOf ann)

    Var ann (Free ident) -> do
      -- Lookup the type of the declaration variable in the context.
      ctx <- getDeclCtx
      case Map.lookup ident ctx of
        Just (checkedType, _) -> return (Var ann (Free ident), checkedType)
        -- This should have been caught during scope checking
        Nothing -> compilerDeveloperError $
          "Declaration'" <+> pretty ident <+> "'not found when" <+>
          "looking up variable in context" <+> pretty (Map.keys ctx) <+> "at" <+> pretty (provenanceOf ann)

    Let ann boundExpr binder body -> do
      -- Check the type of the bound expression against the provided type
      (typeOfBoundExpr, typeOfBoundExprType) <- inferExpr (typeOf binder)
      _ <- unify ann typeOfBoundExprType (Type (inserted ann) 0)
      checkedBoundExpr <- checkExpr typeOfBoundExpr boundExpr

      let checkedBinder = replaceBinderType typeOfBoundExpr binder

      (checkedBody, typeOfBody) <-
        addToBoundCtx (nameOf binder) typeOfBoundExpr (Just checkedBoundExpr) $ inferExpr body

      -- It's possible for the type of the body to depend on the let bound variable,
      -- e.g. `let y = Nat in (2 : y)` so in order to avoid the DeBruijn index escaping
      -- it's context we need to substitute the bound expression into the type.
      normTypeOfBody <- if isMeta typeOfBody
        then return typeOfBody
        else do
          let normTypeOfBody = checkedBoundExpr `substInto` typeOfBody
          when (normTypeOfBody /= typeOfBody) $
            logDebug MaxDetail $ "normalising" <+> prettyVerbose typeOfBody <+> "to" <+> prettyVerbose normTypeOfBody
          return normTypeOfBody

      return (Let ann checkedBoundExpr checkedBinder checkedBody , normTypeOfBody)

    Lam ann binder body -> do
      -- Infer the type of the bound variable from the binder
      (typeOfBinder, typeOfBinderType) <- inferExpr (typeOf binder)

      let insertedAnn = inserted ann
      _ <- unify ann typeOfBinderType (Type insertedAnn 0)
      let checkedBinder = replaceBinderType typeOfBinder binder

      -- Update the context with the bound variable
      (checkedBody , typeOfBody) <-
        addToBoundCtx (nameOf binder) typeOfBinder Nothing $ inferExpr body

      let t' = Pi insertedAnn (removeBinderName checkedBinder) typeOfBody
      return (Lam ann checkedBinder checkedBody , t')

    Builtin p op -> do
      return (Builtin p op, typeOfBuiltin p op)

    LSeq ann dict elems -> do
      let p = provenanceOf ann
      ctx <- getVariableCtx

      -- Infer the type for each element in the list
      (checkedElems, typesOfElems) <- unzip <$> traverse inferExpr elems

      -- Generate a fresh meta variable for the type of elements in the list, e.g. Int
      (_, typeOfElems) <- freshMeta p
      -- Unify the types of all the elements in the sequence
      _ <- foldrM (unify p) typeOfElems typesOfElems

      -- Generate a meta-variable for the applied container type, e.g. List Int
      (_, typeOfContainer) <- freshMeta p
      let typeOfDict = HasConLitsOfSizeExpr ann (length elems) typeOfElems typeOfContainer

      -- Check the type of the dict
      checkedDict <- if not (isHole dict)
        then checkExpr typeOfDict dict
        else do
          (meta, checkedDict) <- freshMeta p
          addTypeClassConstraint ctx meta typeOfDict
          return checkedDict

      -- Return the result
      return (LSeq ann checkedDict checkedElems, typeOfContainer)

    PrimDict ann typeClass -> do
      (checkedTypeClass, typeClassType) <- inferExpr typeClass
      _ <- unify (provenanceOf ann) typeClassType (Type (inserted ann) 0)
      return (PrimDict ann checkedTypeClass, checkedTypeClass)

  showInferExit res
  return res

inferLiteral :: UncheckedAnn -> Literal -> (CheckedExpr, CheckedExpr)
inferLiteral p l = (Literal p l, typeOfLiteral p l)

-- | Takes the expected type of a function and the user-provided arguments
-- and traverses through checking each argument type against the type of the
-- matching pi binder and inserting any required implicit/instance arguments.
-- Returns the type of the function when applied to the full list of arguments
-- (including inserted arguments) and that list of arguments.
inferArgs :: TCM m
          => Provenance     -- Provenance of the function
          -> CheckedExpr    -- Type of the function
          -> [UncheckedArg] -- User-provided arguments of the function
          -> m (CheckedExpr, [CheckedArg])
inferArgs p (Pi _ binder resultType) (arg : args)
  | visibilityOf binder == visibilityOf arg = do
    -- Check the type of the argument.
    checkedArgExpr <- checkExpr (typeOf binder) (argExpr arg)

    -- Generate the new checked arg
    let checkedArg = replaceArgExpr checkedArgExpr arg

    -- Substitute argument in `resultType`
    let updatedResultType = checkedArgExpr `substInto` resultType

    -- Recurse into the list of args
    (typeAfterApplication, checkedArgs) <- inferArgs p updatedResultType args

    -- Return the appropriately annotated type with its inferred kind.
    return (typeAfterApplication, checkedArg : checkedArgs)

  | visibilityOf binder == Explicit = do
    -- Then we're expecting an explicit arg but have a non-explicit arg
    -- so panic
    ctx <- getBoundCtx
    throwError $ MissingExplicitArg ctx arg (typeOf binder)

-- This case handles either
-- `visibilityOf binder /= Explicit` and (`visibilityOf binder /= visibilityOf arg` or args == [])
inferArgs p (Pi _ binder resultType) args
  | visibilityOf binder /= Explicit = do
    logDebug MaxDetail ("insert-arg" <+> pretty (visibilityOf binder) <+> prettyVerbose (typeOf binder))
    let binderVis = visibilityOf binder
    let ann = inserted $ provenanceOf binder

    -- Generate a new meta-variable for the argument
    (meta, metaExpr) <- freshMeta p
    let metaArg = Arg ann binderVis metaExpr

    -- Check if the required argument is a type-class
    when (binderVis == Instance) $ do
      ctx <- getVariableCtx
      addTypeClassConstraint ctx meta (typeOf binder)

    -- Substitute meta-variable in tRes
    let updatedResultType = metaExpr `substInto` resultType

    -- Recurse into the list of args
    (typeAfterApplication, checkedArgs) <- inferArgs p updatedResultType args

    -- Return the appropriately annotated type with its inferred kind.
    return (typeAfterApplication, metaArg : checkedArgs)

inferArgs _p functionType [] = return (functionType, [])

inferArgs p functionType args = do
  ctx <- getBoundCtx
  let ann = inserted p
  let mkRes = [Endo $ \tRes -> pi (visibilityOf arg) (tHole ("arg" <> pack (show i))) (const tRes)
              | (i, arg) <- zip [0::Int ..] args]
  let expectedType = fromDSL ann (appEndo (mconcat mkRes) (tHole "res"))
  throwError $ TypeMismatch p ctx functionType expectedType

-- |Takes a function and its arguments, inserts any needed implicits
-- or instance arguments and then returns the function applied to the full
-- list of arguments as well as the result type.
inferApp :: TCM m
         => CheckedAnn
         -> CheckedExpr
         -> CheckedExpr
         -> [UncheckedArg]
         -> m (CheckedExpr, CheckedExpr)
inferApp ann fun funType args = do
  (appliedFunType, checkedArgs) <- inferArgs (provenanceOf fun) funType args
  varCtx <- getVariableCtx
  normAppliedFunType <- whnfWithMetas varCtx appliedFunType
  return (normAppList ann fun checkedArgs, normAppliedFunType)

--------------------------------------------------------------------------------
-- Typing of literals and builtins

-- | Return the type of the provided literal,
typeOfLiteral :: CheckedAnn -> Literal -> CheckedExpr
typeOfLiteral ann l = fromDSL ann $ case l of
  LNat  n -> forall type0 $ \t -> hasNatLitsUpTo n t ~~~> t
  LInt  _ -> forall type0 $ \t -> hasIntLits t ~~~> t
  LRat  _ -> forall type0 $ \t -> hasRatLits t ~~~> t
  LBool _ -> tBool

-- | Return the type of the provided builtin.
typeOfBuiltin :: CheckedAnn -> Builtin -> CheckedExpr
typeOfBuiltin ann b = fromDSL ann $ case b of
  Bool                      -> type0
  NumericType   _           -> type0
  ContainerType List        -> type0 ~> type0
  ContainerType Tensor      -> type0 ~> tList tNat ~> type0
  Index                     -> tNat ~> type0

  TypeClass HasEq                -> type0 ~> type0
  TypeClass HasOrd               -> type0 ~> type0
  TypeClass HasNatOps            -> type0 ~> type0
  TypeClass HasIntOps            -> type0 ~> type0
  TypeClass HasRatOps            -> type0 ~> type0
  TypeClass HasConOps            -> type0 ~> type0 ~> type0
  TypeClass (HasNatLitsUpTo _)   -> type0 ~> type0
  TypeClass HasIntLits           -> type0 ~> type0
  TypeClass HasRatLits           -> type0 ~> type0
  TypeClass (HasConLitsOfSize _) -> type0 ~> type0 ~> type0

  If           -> typeOfIf
  Not          -> typeOfBoolOp1
  BooleanOp2 _ -> typeOfBoolOp2
  Neg          -> typeOfNumOp1 hasIntOps
  NumericOp2 _ -> typeOfNumOp2 hasNatOps

  Equality _ -> typeOfEqualityOp
  Order    _ -> typeOfComparisonOp

  Cons -> typeOfCons
  At   -> typeOfAtOp
  Map  -> typeOfMapOp
  Fold -> typeOfFoldOp

  Quant   _ -> typeOfQuantifierOp
  QuantIn _ -> typeOfQuantifierInOp

typeOfIf :: DSLExpr
typeOfIf =
  forall type0 $ \t ->
    tBool ~> t ~> t ~> t

typeOfEqualityOp :: DSLExpr
typeOfEqualityOp =
  forall type0 $ \t ->
    hasEq t ~~~> t ~> t ~> tBool

typeOfComparisonOp :: DSLExpr
typeOfComparisonOp =
  forall type0 $ \t ->
    hasOrd t ~~~> t ~> t ~> tBool

typeOfBoolOp2 :: DSLExpr
typeOfBoolOp2 = tBool ~> tBool ~> tBool

typeOfBoolOp1 :: DSLExpr
typeOfBoolOp1 = tBool ~> tBool

typeOfNumOp2 :: (DSLExpr -> DSLExpr) -> DSLExpr
typeOfNumOp2 numConstraint =
  forall type0 $ \t ->
    numConstraint t ~~~> t ~> t ~> t

typeOfNumOp1 :: (DSLExpr -> DSLExpr) -> DSLExpr
typeOfNumOp1 numConstraint =
  forall type0 $ \t ->
    numConstraint t ~~~> t ~> t

typeOfQuantifierOp :: DSLExpr
typeOfQuantifierOp =
  forall type0 $ \t ->
    (t ~> tBool) ~> tBool

typeOfQuantifierInOp :: DSLExpr
typeOfQuantifierInOp =
  forall type0 $ \tElem ->
    forall type0 $ \tCont ->
      hasConOps tElem tCont ~~~> (tElem ~> tBool) ~> tCont ~> tBool

typeOfCons :: DSLExpr
typeOfCons =
  forall type0 $ \tElem ->
    tElem ~> tList tElem ~> tList tElem

typeOfAtOp :: DSLExpr
typeOfAtOp =
  forall type0 $ \tElem ->
    forall type0 $ \tDim ->
      forall type0 $ \tDims ->
        tTensor tElem (cons tDim tDims) ~> tIndex tDim ~> tTensor tElem tDims

-- TODO generalise these to tensors etc. (remember to do mkMap' in utils as well)
typeOfMapOp :: DSLExpr
typeOfMapOp =
  forall type0 $ \tFrom ->
    forall type0 $ \tTo ->
      (tFrom ~> tTo) ~> tList tFrom ~> tList tTo

typeOfFoldOp :: DSLExpr
typeOfFoldOp =
  forall type0 $ \tElem ->
    forall type0 $ \tCont ->
      forall type0 $ \tRes ->
        hasConOps tElem tCont ~~~> (tElem ~> tRes ~> tRes) ~> tRes ~> tCont ~> tRes