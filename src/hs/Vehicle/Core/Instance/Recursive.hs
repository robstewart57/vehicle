{-# OPTIONS_GHC -fno-warn-orphans #-}

{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TypeFamilies      #-}

module Vehicle.Core.Instance.Recursive where

import Control.Monad (join)
import Data.Functor.Foldable.TH
import Vehicle.Core.Type

$(join <$> traverse makeBaseFunctor [''Kind, ''Type, ''Expr])
