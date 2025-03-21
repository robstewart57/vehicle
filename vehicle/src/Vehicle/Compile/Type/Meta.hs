module Vehicle.Compile.Type.Meta
  ( MetaSet,
    MetaInfo (..),
    MetaCtxSize,
    extendMetaCtx,
    HasMetas (..),
    makeMetaType,
    makeMetaExpr,
    getMetaDependencies,
    getNormMetaDependencies,
  )
where

import Vehicle.Compile.Type.Meta.Set (MetaSet)
import Vehicle.Compile.Type.Meta.Variable
