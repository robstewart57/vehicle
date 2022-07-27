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
open import Data.Fin as Fin using (Fin; #_)
open import Data.List
open import Data.Vec.Functional

module andGate-temp-output where

postulate andGate : Tensor ℚ (2 ∷ []) → Tensor ℚ (1 ∷ [])

Truthy : ℚ → Set
Truthy x = x ℚ.≥ ℤ.+ 1 ℚ./ 2

Falsey : ℚ → Set
Falsey x = x ℚ.≤ ℤ.+ 1 ℚ./ 2

ValidInput : ℚ → Set
ValidInput x = ℤ.+ 0 ℚ./ 1 ℚ.≤ x × x ℚ.≤ ℤ.+ 1 ℚ./ 1

CorrectOutput : ℚ → (ℚ → Set)
CorrectOutput x1 x2 = let y = andGate (x1 ∷ (x2 ∷ [])) (# 0) in (Truthy x1 × Truthy x2 → Truthy y) × ((Truthy x1 × Falsey x2 → Falsey y) × ((Falsey x1 × Truthy x2 → Falsey y) × (Falsey x1 × Falsey x2 → Falsey y)))

abstract
  andGateCorrect : ∀ (x1 : ℚ) → ∀ (x2 : ℚ) → ValidInput x1 × ValidInput x2 → CorrectOutput x1 x2
  andGateCorrect = checkSpecification record
    { proofCache   = "/home/matthew/Code/AISEC/vehicle/proofcache.vclp"
    }