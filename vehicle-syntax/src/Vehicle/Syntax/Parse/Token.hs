module Vehicle.Syntax.Parse.Token where

import Data.Coerce (Coercible, coerce)
import Data.Function (on)
import Data.Text (Text)
import Data.Text qualified as T

-- | Position tokens in BNFC generated grammars are represented by a pair of a
--  position and the text token.
newtype Token = Tk ((Int, Int), Text)
  deriving (Eq, Ord, Show, Read)

pattern Token :: (Int, Int) -> Text -> Token
pattern Token {pos, sym} = Tk (pos, sym)

type TokenConstructor a = ((Int, Int), Text) -> a

mkToken :: TokenConstructor a -> Text -> a
mkToken mk s = mk ((0, 0), s)

-- | Constraint for newtypes which are /position tokens/. Depends on the fact
--   that any /position token/ generated by BNFC with @--text@ will be a newtype
--   wrapping '(Position, Name)', and hence all are coercible to it. This breaks
--   if the @--text@ option is not passed, or if the token is not marked with the
--   @position@ keyword.
type IsToken a = Coercible a Token

-- | Convert from 'Token' to an arbitrary newtype via 'Coercible'.
toToken :: IsToken a => a -> Token
toToken = coerce

-- | Convert to 'Token' from an arbitrary newtype via 'Coercible'.
fromToken :: IsToken a => Token -> a
fromToken = coerce

-- | Get the symbol of a token.
tkSymbol :: IsToken a => a -> Text
tkSymbol = sym . toToken

-- | Get the length of a token.
tkLength :: IsToken a => a -> Int
tkLength = T.length . tkSymbol

-- | Compare the text portion of any two position tokens.
tkEq :: IsToken a => a -> a -> Bool
tkEq = (==) `on` toToken

-- | Get the starting position of a token.
tkLocation :: IsToken a => a -> (Int, Int)
tkLocation = pos . toToken

-- | Change name of a token.
tkUpdateText :: IsToken a => Text -> a -> a
tkUpdateText txt tk = fromToken (Token {pos = tkLocation tk, sym = txt})
