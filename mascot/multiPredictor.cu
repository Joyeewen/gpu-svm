/*
 * multiPredictor.cu
 *
 *  Created on: 1 Jan 2017
 *      Author: Zeyi Wen
 */

#include <cuda.h>
#include <helper_cuda.h>
#include <driver_types.h>
#include <cuda_runtime_api.h>
#include <cuda_profiler_api.h>
#include <assert.h>
#include "multiPredictor.h"
#include "predictionGPUHelper.h"
#include "classifierEvaluater.h"
#include "../svm-shared/constant.h"
#include "../SharedUtility/CudaMacro.h"
#include <iostream>
using namespace std;
real MultiPredictor::sigmoidPredict(real decValue, real A, real B) const {
    double fApB = decValue * A + B;
    // 1-p used later; avoid catastrophic cancellation
    if (fApB >= 0)
        return exp(-fApB) / (1.0 + exp(-fApB));
    else
        return 1.0 / (1 + exp(fApB));
}

void MultiPredictor::multiClassProbability(const vector<vector<real> > &r, vector<real> &p) const {
	int nrClass = model.nrClass;
    int t, j;
    int iter = 0, max_iter = max(100, nrClass);
    double **Q = (double **) malloc(sizeof(double *) * nrClass);
    double *Qp = (double *) malloc(sizeof(double) * nrClass);
    double pQp, eps = 0.005 / nrClass;

    for (t = 0; t < nrClass; t++) {
        p[t] = 1.0 / nrClass;  // Valid if k = 1
        Q[t] = (double *) malloc(sizeof(double) * nrClass);
        Q[t][t] = 0;
        for (j = 0; j < t; j++) {
            Q[t][t] += r[j][t] * r[j][t];
            Q[t][j] = Q[j][t];
        }
        for (j = t + 1; j < nrClass; j++) {
            Q[t][t] += r[j][t] * r[j][t];
            Q[t][j] = -r[j][t] * r[t][j];
        }
    }
    for (iter = 0; iter < max_iter; iter++) {
        // stopping condition, recalculate QP,pQP for numerical accuracy
        pQp = 0;
        for (t = 0; t < nrClass; t++) {
            Qp[t] = 0;
            for (j = 0; j < nrClass; j++)
                Qp[t] += Q[t][j] * p[j];
            pQp += p[t] * Qp[t];
        }
        double max_error = 0;
        for (t = 0; t < nrClass; t++) {
            double error = fabs(Qp[t] - pQp);
            if (error > max_error)
                max_error = error;
        }
        if (max_error < eps)
            break;

        for (t = 0; t < nrClass; t++) {
            double diff = (-Qp[t] + pQp) / Q[t][t];
            p[t] += diff;
            pQp = (pQp + diff * (diff * Q[t][t] + 2 * Qp[t])) / (1 + diff)
                  / (1 + diff);
            for (j = 0; j < nrClass; j++) {
                Qp[j] = (Qp[j] + diff * Q[t][j]) / (1 + diff);
                p[j] /= (1 + diff);
            }
        }
    }
    if (iter >= max_iter)
        printf("Exceeds max_iter in multiclass_prob\n");
    for (t = 0; t < nrClass; t++)
        free(Q[t]);
    free(Q);
    free(Qp);
}

vector<vector<real> > MultiPredictor::predictProbability(const vector<vector<KeyValue> > &v_vSamples, const vector<int> &vnOriginalLabel) const {
	int nrClass = model.nrClass;
    vector<vector<real> > result;
    vector<vector<real> > decValues;
    computeDecisionValues(v_vSamples, decValues);
    for (int l = 0; l < v_vSamples.size(); ++l) {
        vector<vector<real> > r(nrClass, vector<real>(nrClass));
        double min_prob = 1e-7;
        int k = 0;
        for (int i = 0; i < nrClass; i++)
            for (int j = i + 1; j < nrClass; j++) {
                r[i][j] = min(
                        max(sigmoidPredict(decValues[l][k], model.probA[k], model.probB[k]), min_prob), 1 - min_prob);
                r[j][i] = 1 - r[i][j];
                k++;
            }
        if(!vnOriginalLabel.empty())//want to measure sub-classifier error
        	ClassifierEvaluater::collectSubSVMInfo(model, l, vnOriginalLabel[l], nrClass, r, true);
        vector<real> p(nrClass);
        multiClassProbability(r, p);
        result.push_back(p);
    }
    return result;
}

/**
 * @brief: compute the decision value
 */
void MultiPredictor::computeDecisionValues(const vector<vector<KeyValue> > &v_vSamples,
                        		   vector<vector<real> > &decisionValues) const {
    //copy samples to device
    CSRMatrix sampleCSRMat(v_vSamples, model.numOfFeatures);
    real *devSampleVal;
    real *devSampleValSelfDot;
    int *devSampleRowPtr;
    int *devSampleColInd;
    int sampleNnz = sampleCSRMat.getNnz();
    checkCudaErrors(cudaMalloc((void **) &devSampleVal, sizeof(real) * sampleNnz));
    checkCudaErrors(cudaMalloc((void **) &devSampleValSelfDot, sizeof(real) * sampleCSRMat.getNumOfSamples()));
    checkCudaErrors(cudaMalloc((void **) &devSampleRowPtr, sizeof(int) * (sampleCSRMat.getNumOfSamples() + 1)));
    checkCudaErrors(cudaMalloc((void **) &devSampleColInd, sizeof(int) * sampleNnz));
    checkCudaErrors(cudaMemcpy(devSampleVal, sampleCSRMat.getCSRVal(), sizeof(real) * sampleNnz,
                               cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(devSampleValSelfDot, sampleCSRMat.getCSRValSelfDot(),
                               sizeof(real) * sampleCSRMat.getNumOfSamples(), cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(devSampleRowPtr, sampleCSRMat.getCSRRowPtr(),
    						   sizeof(int) * (sampleCSRMat.getNumOfSamples() + 1), cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(devSampleColInd, sampleCSRMat.getCSRColInd(), sizeof(int) * sampleNnz,
    						   cudaMemcpyHostToDevice));

    cusparseHandle_t handle;
    cusparseMatDescr_t descr;
    cusparseCreate(&handle);
    cusparseCreateMatDescr(&descr);
    cusparseSetMatIndexBase(descr, CUSPARSE_INDEX_BASE_ZERO);
    cusparseSetMatType(descr, CUSPARSE_MATRIX_TYPE_GENERAL);
    real *devKernelValues;
    checkCudaErrors(cudaMalloc((void **) &devKernelValues,
    						   sizeof(real) * v_vSamples.size() * model.svMap.size()));

    //dot product between sv and sample
    CSRMatrix::CSRmm2Dense(handle, CUSPARSE_OPERATION_NON_TRANSPOSE, CUSPARSE_OPERATION_TRANSPOSE,
                           sampleCSRMat.getNumOfSamples(), model.svMapCSRMat->getNumOfSamples(),
						   model.svMapCSRMat->getNumOfFeatures(),
                           descr, sampleNnz, devSampleVal, devSampleRowPtr, devSampleColInd,
                           descr, model.svMapCSRMat->getNnz(), model.devSVMapVal, model.devSVMapRowPtr, model.devSVMapColInd,
                           devKernelValues);

    //obtain exp(-gamma*(a^2+b^2-2ab))
    int numOfBlock = Ceil(v_vSamples.size() * model.svMap.size(), BLOCK_SIZE);
    rbfKernel<<<numOfBlock, BLOCK_SIZE>>>(devSampleValSelfDot, sampleCSRMat.getNumOfSamples(),
                            		      model.devSVMapValSelfDot, model.svMapCSRMat->getNumOfSamples(),
										  devKernelValues, model.param.gamma);

    //sum kernel values of each model then obtain decision values
    int cnr2 = model.cnr2;
    numOfBlock = Ceil(v_vSamples.size() * cnr2, BLOCK_SIZE);
    real *devDecisionValues;
    checkCudaErrors(cudaMalloc((void **) &devDecisionValues, sizeof(real) * v_vSamples.size() * cnr2));
    sumKernelValues<<<numOfBlock, BLOCK_SIZE>>>(devKernelValues, v_vSamples.size(),
    				model.svMapCSRMat->getNumOfSamples(), cnr2, model.devSVIndex,
					model.devCoef, model.devStart, model.devCount, model.devRho, devDecisionValues);
    real *tempDecValues = new real[v_vSamples.size() * cnr2];
    checkCudaErrors(cudaMemcpy(tempDecValues, devDecisionValues,
                               sizeof(real) * v_vSamples.size() * cnr2, cudaMemcpyDeviceToHost));
    decisionValues = vector<vector<real> >(v_vSamples.size(), vector<real>(cnr2));
    for (int i = 0; i < decisionValues.size(); ++i) {
        memcpy(decisionValues[i].data(), tempDecValues + i * cnr2, sizeof(real) * cnr2);
    }
    delete[] tempDecValues;
    checkCudaErrors(cudaFree(devDecisionValues));
    checkCudaErrors(cudaFree(devKernelValues));
    checkCudaErrors(cudaFree(devSampleVal));
    checkCudaErrors(cudaFree(devSampleValSelfDot));
    checkCudaErrors(cudaFree(devSampleRowPtr));
    checkCudaErrors(cudaFree(devSampleColInd));
    cusparseDestroy(handle);
    cusparseDestroyMatDescr(descr);
}

/**
 * @brief: predict the label of the instances
 * @param: vnOriginalLabel is for computing errors of sub-classifier.
 */
vector<int> MultiPredictor::predict(const vector<vector<KeyValue> > &v_vSamples, const vector<int> &vnOriginalLabel) const{
	int nrClass = model.nrClass;
    int manyClassIns=0;
	bool probability = model.isProbability();
    vector<int> labels;
    if (!probability) {
        vector<vector<real> > decisionValues;
        computeDecisionValues(v_vSamples, decisionValues);
			cout<<"sample "<<v_vSamples[0][0].featureValue<<endl;
			cout<<"sample "<<v_vSamples[0][1].featureValue<<endl;
			cout<<"sample "<<v_vSamples[0][2].featureValue<<endl;
        for (int l = 0; l < v_vSamples.size(); ++l) {
        	if(!vnOriginalLabel.empty())//want to measure sub-classifier error
	            ClassifierEvaluater::collectSubSVMInfo(model, l, vnOriginalLabel[l], nrClass, decisionValues, false);

            vector<int> votes(nrClass, 0);
            int k = 0;
            for (int i = 0; i < nrClass; ++i) {
                for (int j = i + 1; j < nrClass; ++j) {
		    if(l<1){
		       cout<<"gpu decisionvalue for 1 instance "<<decisionValues[l][k]<<endl;
 		    }
                    if (decisionValues[l][k++] > 0)
                    	votes[i]++;
                    else
                    	votes[j]++;
                }
            }
            int maxVoteClass = 0;
            for (int i = 0; i < nrClass; ++i) {
                if (votes[i] > votes[maxVoteClass])
                    maxVoteClass = i;
            }
            labels.push_back(model.label[maxVoteClass]);
	    if(l<20){
	        cout<<"****************predict 10 label"<<endl;
		//cout<<"maxvote "<<maxVoteClass<<endl;
		//cout<<"max label "<<model.label[maxVoteClass]<<endl;
		}
            //compute #instance that belong to more than one classes
            int flag=0;
            for(int i=0;i<nrClass;i++)
                for(int j=i+1;j<nrClass;j++){
                    if(votes[i]==votes[j]){
                        flag++;
                        break;
                    }
                }
            if(flag>0)
                manyClassIns++;
        }
       // printf("number of instance belong to manyClass %.2f%%%(%d,%d)\n",manyClassIns/ (float) v_vSamples.size(), manyClassIns,v_vSamples.size());
    } else {
        assert(model.probability);
        vector<vector<real> > prob = predictProbability(v_vSamples, vnOriginalLabel);
        // todo select max using GPU
        for (int i = 0; i < v_vSamples.size(); ++i) {
            int maxProbClass = 0;
            for (int j = 0; j < nrClass; ++j) {
                if (prob[i][j] > prob[i][maxProbClass])
                    maxProbClass = j;
            }
            labels.push_back(model.label[maxProbClass]);
        }
    }
    return labels;
}

void MultiPredictor::predictDecValue(vector<real> &combDecValue, const vector<vector<KeyValue> > &v_vSamples) const{
    int nrClass = model.nrClass;

        vector<vector<real> > decisionValues;
        computeDecisionValues(v_vSamples, decisionValues);

        for (int l = 0; l < v_vSamples.size(); ++l) {
            combDecValue.push_back(decisionValues[l][0]);

        }

}
