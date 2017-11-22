# ThunderSVM
[![Build Status](https://travis-ci.org/zeyiwen/thundersvm.svg?branch=master)](https://travis-ci.org/zeyiwen/thundersvm)

<div align="center">
<img src="https://github.com/zeyiwen/thundersvm/raw/master/docs/_static/lang-logo.png" width="250" height="200" align=left/>
<img src="https://github.com/zeyiwen/thundersvm/raw/master/docs/_static/overall.png" width="250" height="200" align=left/>
</div>

## Overview
The mission of ThunderSVM is to help users easily and efficiently apply SVMs to solve problems. GPU blabla.. Some key features of ThunderSVM are as follows.
* Support one-class, binary and multi-class SVM classification, SVM regression, and SVMs with probability outputs (the same functionality as LibSVM)
* Have Python, R and Matlab interfaces (entirely compatible with LibSVM)

## Contents
- [Getting Started](https://github.com/zeyiwen/thundersvm/tree/improve-doc#getting-started)
- [Advanced](https://github.com/zeyiwen/thundersvm/tree/improve-doc#advanced)
- [Working without GPUs](https://github.com/zeyiwen/thundersvm/tree/improve-doc#working-without-gpus)
- [Documentations](http://thundersvm.readthedocs.io)
- [API Reference (doxygen)](http://zeyiwen.github.io/thundersvm/)

## Getting Started
### Prerequisites
* Operating system: 
* [CUDA](https://developer.nvidia.com/cuda-downloads)
* cmake 2.8 or above
* gcc 4.8 or above
### Download
```bash
git clone git@github.com:zeyiwen/thundersvm.git
```
### Build
```bash
cd thundersvm
mkdir build && cd build && cmake .. && make -j
```
### Quick Start
```bash
bin\thundersvm-train -c 100 -g 0.5 ../dataset/test_dataset.txt
bin\thundersvm-predict ../dataset/test_dataset.txt test_dataset.model test_dataset.predict
```
You will see `Accuracy = 0.98` after successful running.

## Advanced
## Working without GPUs
If you don't have GPUs, ThunderSVM can work with CPU only.
### Get Eigen Library
ThunderSVM uses [Eigen](http://eigen.tuxfamily.org/index.php?title=Main_Page) for matrix calculation. To use Eigen, just 
initialize the submodule. 
```bash
# in thundersvm root directory
git submodule init eigen && git submodule update
```
### Build without GPUs
```bash
# in thundersvm root directory
mkdir build && cd build && cmake -DUSE_CUDA=OFF -DUSE_EIGEN=ON .. && make -j
```
Now ThunderSVM will work solely on CPUs and does not rely on CUDA.

## Related websites
* [LibSVM](https://www.csie.ntu.edu.tw/~cjlin/libsvm/)
* [SVM<sup>light</sup>](http://svmlight.joachims.org/)
* [OHD-SVM](https://github.com/OrcusCZ/OHD-SVM)
* [NVIDIA Machine Learning](http://www.nvidia.com/object/machine-learning.html). 

## TODO
- integrate with interfaces

## Acknowlegement 
* NVIDIA: We acknowledge NVIDIA for their hardware donations.
* This project is hosted by NUS, collaborating with Prof. Jian Chen (xxxx).
