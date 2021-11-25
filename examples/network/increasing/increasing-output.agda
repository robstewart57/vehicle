-- WARNING: This file was generated automatically by Vehicle
-- and should not be modified manually!
-- Metadata
--  - Agda version: 2.6.2
--  - AISEC version: 0.1.0.1
--  - Time generated: ???

open import Vehicle
open import Vehicle.Data.Tensor
open import Data.Real as ℝ using (ℝ)
open import Data.List

module MyTestModule where

private
  VEHICLE_PROJECT_FILE = TODO/vehicle/path

f : Tensor ℝ (1 ∷ []) → Tensor ℝ (1 ∷ [])
f = evaluate record
  { projectFile = VEHICLE_PROJECT_FILE
  ; networkUUID = NETWORK_UUID
  }

abstract
  increasing : ∀ (x : Tensor ℝ (1 ∷ [])) → let y = f x in x 0 ℝ.≤ y 0
  increasing = checkProperty record
    { projectFile  = VEHICLE_PROJECT_FILE
    ; propertyUUID = ????
    }