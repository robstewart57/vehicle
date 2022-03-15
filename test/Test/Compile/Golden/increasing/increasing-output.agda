-- WARNING: This file was generated automatically by Vehicle
-- and should not be modified manually!
-- Metadata
--  - Agda version: 2.6.2
--  - AISEC version: 0.1.0.1
--  - Time generated: ???

{-# OPTIONS --allow-exec #-}

open import Vehicle
open import Data.Rational as ℝ using () renaming (ℚ to ℝ)

module increasing-temp-output where

postulate f : ℝ → ℝ

abstract
  increasing : ∀ (x : ℝ) → x ℝ.≤ f x
  increasing = checkProperty record
    { proofCache   = "/home/matthew/Code/AISEC/vehicle/proofcache.vclp"
    ; propertyUUID = "TODO_propertyUUID"
    }