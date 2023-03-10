#!/bin/sh

echo "epochs,DL,ratio,accuracy" > classification-data.csv
echo "epochs,DL,ratio,delta,satisfaction" > constraint-data.csv

export EPOCHV="10"
export RATIOV="95"
export DLV="LossFunction-DL2"

poetry run python3 tests/test_mnist_custom_loss.py
