# ANSYS LS-Dyna

Ansys [LS-Dyna](https://www.ansys.com/products/structures/ansys-ls-dyna) is a multi-physics solver using the finite-element method (FEM). It is commonly used in many different areas in computer aided engineering (CAE), especially the explicit solver for crash simulations.


## Contribute your results

The benchmark scripts in this folder call [`dynamodb/record-benchmark.sh`](dynamodb/record-benchmark.sh) after every successful run. The recorder saves the run as a small JSON record (`<record_id>.json`) and adds it to the shared AI-Powered HPC benchmark dataset when you have write access to it. That dataset trains a model that predicts HPC performance on AWS, so every result you share helps. Set `SOURCE=<YourOrg>` to tag your runs, and see [BENCHMARK-RECORDERS.md](../BENCHMARK-RECORDERS.md) for the options and how to send the record in.
