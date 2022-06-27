module Test.Compile.Unit.CoDeBruijn
  ( coDeBruijnTests ) where

import Test.Tasty
import Test.Tasty.HUnit

import Control.Exception
import Control.Monad.Except (MonadError(..), ExceptT, runExceptT)
import Data.Text
import Data.Hashable
import Data.IntMap qualified as IntMap

import Vehicle.Language.Print
import Vehicle.Compile.Prelude
import Vehicle.Compile (typeCheckExpr)
import Vehicle.Compile.AlphaEquivalence
import Vehicle.Compile.Error
import Vehicle.Compile.CoDeBruijnify

import Test.Compile.Utils

--------------------------------------------------------------------------------
-- Alpha equivalence tests

coDeBruijnTests :: MonadTest m => m TestTree
coDeBruijnTests = testGroup "CoDeBruijnIndices" <$>
  traverse toFromCoDB
  [ CoDeBruijnTestSpec "type"    "Nat"
  , CoDeBruijnTestSpec "typeFun" "Nat -> Nat"
  , CoDeBruijnTestSpec "lam"     "\\(x : Nat) -> x"
  , CoDeBruijnTestSpec "lam2"    "\\(f : Nat -> Nat) (x : Nat) -> f x"
  , CoDeBruijnTestSpec "pi"      "forallT (n : Nat) . Tensor Nat [n]"
  , CoDeBruijnTestSpec "neg"     "\\(x : Int) -> - x"
  ]

data CoDeBruijnTestSpec = CoDeBruijnTestSpec String Text

toFromCoDB :: MonadTest m => CoDeBruijnTestSpec -> m TestTree
toFromCoDB (CoDeBruijnTestSpec testName e1) =
  unitTestCase testName $ do
    e2 <- typeCheckExpr e1
    let e3 = toCoDBExpr e2
    let e4 = fromCoDB e3

    let errorMessage = layoutAsString $
          "Expected:" <+> line <> indent 2 (
            squotes (prettyVerbose e2)  <> line <>
            squotes (prettyVerbose e4)) <> line <>
          "to be equal" <>
          "\n\n" <>
          "CoDB parse:" <+> line <> indent 2 (
            squotes (prettyVerbose e3))

    return $ assertBool errorMessage (e2 == e4)