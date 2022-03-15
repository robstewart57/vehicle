-- WARNING: This file was generated automatically by Vehicle
-- and should not be modified manually!
-- Metadata
--  - Agda version: 2.6.2
--  - AISEC version: 0.1.0.1
--  - Time generated: ???

{-# OPTIONS --allow-exec #-}

open import Vehicle
open import Vehicle.Data.Tensor
open import Data.Product
open import Data.Integer as ℤ using (ℤ)
open import Data.Rational as ℚ using (ℚ)
open import Data.Fin as Fin using (#_)
open import Data.List

module windController-temp-output where

InputVector : Set
InputVector = Tensor ℚ (2 ∷ [])

postulate controller : InputVector → ℚ

currentSensor : InputVector → ℚ
currentSensor x = x (# 0)

previousSensor : InputVector → ℚ
previousSensor x = x (# 1)

SafeInput : InputVector → Set
SafeInput x = (ℚ.- (ℤ.+ 13 ℚ./ 4) ℚ.≤ currentSensor x × currentSensor x ℚ.≤ ℤ.+ 13 ℚ./ 4) × (ℚ.- (ℤ.+ 13 ℚ./ 4) ℚ.≤ previousSensor x × previousSensor x ℚ.≤ ℤ.+ 13 ℚ./ 4)

SafeOutput : InputVector → Set
SafeOutput x = ℚ.- (ℤ.+ 5 ℚ./ 4) ℚ.< (controller x ℚ.+ (ℤ.+ 2 ℚ./ 1) ℚ.* currentSensor x) ℚ.- previousSensor x × (controller x ℚ.+ (ℤ.+ 2 ℚ./ 1) ℚ.* currentSensor x) ℚ.- previousSensor x ℚ.< ℤ.+ 5 ℚ./ 4

abstract
  safe : ∀ (x : Tensor ℚ (2 ∷ [])) → SafeInput x → SafeOutput x
  safe = checkProperty record
    { proofCache   = "/home/matthew/Code/AISEC/vehicle/proofcache.vclp"
    }