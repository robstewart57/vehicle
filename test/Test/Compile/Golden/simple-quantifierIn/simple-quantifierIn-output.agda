-- WARNING: This file was generated automatically by Vehicle
-- and should not be modified manually!
-- Metadata
--  - Agda version: 2.6.2
--  - AISEC version: 0.1.0.1
--  - Time generated: ???

{-# OPTIONS --allow-exec #-}

open import Vehicle
open import Data.Unit
open import Data.Integer as ℤ using (ℤ)
open import Data.List
open import Data.List.Relation.Unary.All as List

module simple-quantifierIn-temp-output where

emptyList : List ℤ
emptyList = []

abstract
  empty : List.All (λ (x : ℤ) → ⊤) emptyList
  empty = checkProperty record
    { proofCache   = "/home/matthew/Code/AISEC/vehicle/proofcache.vclp"
    }