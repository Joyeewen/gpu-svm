//
// Created by ss on 16-12-14.
//

#include <sys/time.h>
#include <cfloat>
#include "multiSmoSolver.h"
#include "../svm-shared/constant.h"
#include "cuda_runtime.h"
#include "../svm-shared/smoGPUHelper.h"
#include "../svm-shared/HessianIO/deviceHessianOnFly.h"
#include "../SharedUtility/Timer.h"
#include "trainClassifier.h"
#include <thrust/sort.h>
#include <thrust/device_ptr.h>
#include "../svm-shared/devUtility.h"
#include "../svm-shared/Cache/subHessianCalculator.h"

void MultiSmoSolver::solve() {
    int nrClass = problem.getNumOfClasses();

   if (model.vC.size() == 0) {//initialize C for all the binary classes
        model.vC = vector<float_point>(nrClass * (nrClass - 1) / 2, param.C);
    }

    printf("q = %d, working set size = %d\n", q, workingSetSize);
    //train nrClass*(nrClass-1)/2 binary models
    int k = 0;
	vector<int> prob_start(problem.start);
    for (int i = 0; i < nrClass; ++i) {
        int ci=problem.count[i];
        for (int j = i + 1; j < nrClass; ++j) {
            printf("training classifier with label %d and %d\n", i, j);
            SvmProblem subProblem = problem.getSubProblem(i, j);
            init4Training(subProblem);
            CSRMatrix subProblemMat(subProblem.v_vSamples, subProblem.getNumOfFeatures());
            subProblemMat.copy2Dev(devVal, devRowPtr, devColInd, devSelfDot);
            nnz = subProblemMat.getNnz();
            printf("#positive ins %d, #negative ins %d\n", subProblem.count[0], subProblem.count[1]);
            int totalIter = 0;
            TIMER_START(trainingTimer)
            for (int l = 0;; ++l) {
                if (l == 0) {
                    selectWorkingSetAndPreCompute(subProblem, workingSetSize / 2);
                } else {
                    selectWorkingSetAndPreCompute(subProblem, q / 2);
                }
                TIMER_START(iterationTimer)
                localSMO << < 1, workingSetSize, workingSetSize * sizeof(float) * 3 + 2 * sizeof(float) >> >
                                                 (devLabel, devYiGValue, devAlpha, devAlphaDiff, devWorkingSet, workingSetSize, param.C, devHessianMatrixCache, subProblem.getNumOfSamples());
                TIMER_STOP(iterationTimer)
                TIMER_START(updateGTimer)
                updateF << < gridSize, BLOCK_SIZE >> >
                                       (devYiGValue, devLabel, devWorkingSet, workingSetSize, devAlphaDiff, devHessianMatrixCache, subProblem.getNumOfSamples());
                TIMER_STOP(updateGTimer)
                float diff;
                checkCudaErrors(cudaMemcpyFromSymbol(&diff, devDiff, sizeof(float_point), 0, cudaMemcpyDeviceToHost));
                if (l % 10 == 0)
                    printf(".");
                cout.flush();
                if (diff < EPS) {
                    printf("\nup + low = %f\n", diff);
                    break;
                }
            }
            TIMER_STOP(trainingTimer)
            subProblemMat.freeDev(devVal, devRowPtr, devColInd, devSelfDot);
            vector<int> svIndex;
            vector<float_point> coef;
            float_point rho;
            
            
			extractModel(subProblem, svIndex, coef, rho);
            //countPosiSV(subProblem, svIndex, coef, rho,posi_svcount);
            //model.addBinaryModel(subProblem, svIndex, coef, rho, i, j);
            model.addBinaryLibModel(subProblem, svIndex, coef, rho, i, j, prob_start, ci);
			//******new code for save libmodel
			//int posi_svcount=0;
			//extractLibModel(subProblem, svIndex, coef, rho, nSVi, nSVj, posi_svcount);
	        //model.addBinaryLibModel(subProblem, svIndex, coef, rho, i, j, nSVi, nSVj, model.nonzero, prob_start);
	        //******end new code
	        k++;
            deinit4Training();
        }
    }
}

void MultiSmoSolver::init4Training(const SvmProblem &subProblem) {
    unsigned int trainingSize = subProblem.getNumOfSamples();

    checkCudaErrors(cudaMalloc((void **) &devAlpha, sizeof(float_point) * trainingSize));
    checkCudaErrors(cudaMalloc((void **) &devYiGValue, sizeof(float_point) * trainingSize));
    checkCudaErrors(cudaMalloc((void **) &devLabel, sizeof(int) * trainingSize));

    checkCudaErrors(cudaMemset(devAlpha, 0, sizeof(float_point) * trainingSize));
    vector<float_point> negatedLabel(trainingSize);
    for (int i = 0; i < trainingSize; ++i) {
        negatedLabel[i] = -subProblem.v_nLabels[i];
    }
    checkCudaErrors(cudaMemcpy(devYiGValue, negatedLabel.data(), sizeof(float_point) * trainingSize,
                               cudaMemcpyHostToDevice));
    checkCudaErrors(
            cudaMemcpy(devLabel, subProblem.v_nLabels.data(), sizeof(int) * trainingSize, cudaMemcpyHostToDevice));

    InitSolver(trainingSize);//initialise base solver

    checkCudaErrors(cudaMalloc((void **) &devHessianMatrixCache, sizeof(float_point) * workingSetSize * trainingSize));

    for (int j = 0; j < trainingSize; ++j) {
        hessianDiag[j] = 1;//assume using RBF kernel
    }
    checkCudaErrors(
            cudaMemcpy(devHessianDiag, hessianDiag, sizeof(float_point) * trainingSize, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMalloc((void **) &devFValue4Sort, sizeof(float_point) * trainingSize));
    checkCudaErrors(cudaMalloc((void **) &devIdx4Sort, sizeof(int) * trainingSize));

}

void MultiSmoSolver::deinit4Training() {
    checkCudaErrors(cudaFree(devAlpha));
    checkCudaErrors(cudaFree(devYiGValue));
    checkCudaErrors(cudaFree(devLabel));

    DeInitSolver();

    checkCudaErrors(cudaFree(devHessianMatrixCache));
    checkCudaErrors(cudaFree(devFValue4Sort));
    checkCudaErrors(cudaFree(devIdx4Sort));
}

void MultiSmoSolver::extractModel(const SvmProblem &subProblem, vector<int> &svIndex, vector<float_point> &coef,
                                  float_point &rho) const {
    const unsigned int trainingSize = subProblem.getNumOfSamples();
    vector<float_point> alpha(trainingSize);
    const vector<int> &label = subProblem.v_nLabels;
    checkCudaErrors(cudaMemcpy(alpha.data(), devAlpha, sizeof(float_point) * trainingSize, cudaMemcpyDeviceToHost));
    for (int i = 0; i < trainingSize; ++i) {
        if (alpha[i] != 0) {
            coef.push_back(label[i] * alpha[i]);
            svIndex.push_back(i);
            
        }
    }
    checkCudaErrors(cudaMemcpyFromSymbol(&rho, devRho, sizeof(float_point), 0, cudaMemcpyDeviceToHost));
    printf("# of SV %lu\nbias = %f\n", svIndex.size(), rho);
}

// void MultiSmoSolver::countPosiSV(const SvmProblem &subProblem, vector<int> &svIndex, vector<float_point> &coef,
//                                   float_point &rho, int posi_svcount) const {
// 	const unsigned int trainingSize = subProblem.getNumOfSamples();
// 	vector<float_point> alpha(trainingSize);
// 	const vector<int> &label = subProblem.v_nLabels;
// 	checkCudaErrors(cudaMemcpy(alpha.data(), devAlpha, sizeof(float_point) * trainingSize, cudaMemcpyDeviceToHost));
// 	for (int i = 0; i < trainingSize; ++i) {
// 		if (alpha[i] != 0) {
//             if(label[i]>0){ 
//                 posi_svcount++;
			
// 		}																        }
// 	checkCudaErrors(cudaMemcpyFromSymbol(&rho, devRho, sizeof(float_point), 0, cudaMemcpyDeviceToHost));
// 	printf("# of SV %lu\nbias = %f\n", svIndex.size(), rho);
																	
// }
// }

MultiSmoSolver::MultiSmoSolver(const SvmProblem &problem, SvmModel &model, const SVMParam &param) :
        problem(problem), model(model), param(param) {
    q = 256;
    workingSetSize = 512;
    //workingSetSize must be 2^n and less than 1024
    assert(workingSetSize <= 1024);
    for (int i = 0; i < problem.getNumOfClasses(); ++i) {
        assert(workingSetSize <= problem.count[i]);
    }
    workingSet = vector<int>(workingSetSize);
    checkCudaErrors(cudaMalloc((void **) &devAlphaDiff, sizeof(float_point) * workingSetSize));
    checkCudaErrors(cudaMalloc((void **) &devWorkingSet, sizeof(int) * workingSetSize));
}

MultiSmoSolver::~MultiSmoSolver() {
    checkCudaErrors(cudaFree(devAlphaDiff));
    checkCudaErrors(cudaFree(devWorkingSet));
}

void MultiSmoSolver::selectWorkingSetAndPreCompute(const SvmProblem &subProblem, uint numOfSelectPairs) {
    uint numOfSamples = subProblem.getNumOfSamples();
    uint oldSize = workingSetSize / 2 - numOfSelectPairs;
    TIMER_START(selectTimer)
    thrust::device_ptr<float> valuePointer = thrust::device_pointer_cast(devFValue4Sort);
    thrust::device_ptr<int> indexPointer = thrust::device_pointer_cast(devIdx4Sort);
    vector<int> oldWorkingSet = workingSet;

    //get q most violation pairs
    getFUpValues << < gridSize, BLOCK_SIZE >> >
                                (devYiGValue, devAlpha, devLabel, numOfSamples, param.C, devFValue4Sort, devIdx4Sort);
    thrust::sort_by_key(valuePointer, valuePointer + numOfSamples, indexPointer, thrust::greater<float>());
    checkCudaErrors(cudaMemcpy(workingSet.data() + oldSize * 2, devIdx4Sort, sizeof(int) * numOfSelectPairs,
                               cudaMemcpyDeviceToHost));
    getFLowValues << < gridSize, BLOCK_SIZE >> >
                                 (devYiGValue, devAlpha, devLabel, numOfSamples, param.C, devFValue4Sort, devIdx4Sort);
    thrust::sort_by_key(valuePointer, valuePointer + numOfSamples, indexPointer, thrust::greater<float>());
    checkCudaErrors(
            cudaMemcpy(workingSet.data() + oldSize * 2 + numOfSelectPairs, devIdx4Sort, sizeof(int) * numOfSelectPairs,
                       cudaMemcpyDeviceToHost));

    //get pairs from last working set
    for (int i = 0; i < oldSize * 2; ++i) {
        workingSet[i] = oldWorkingSet[numOfSelectPairs * 2 + i];
    }
    checkCudaErrors(cudaMemcpy(devWorkingSet, workingSet.data(), sizeof(int) * workingSetSize, cudaMemcpyHostToDevice));
    TIMER_STOP(selectTimer)

    //move old kernel values to get space
    checkCudaErrors(cudaMemcpy(devHessianMatrixCache,
                               devHessianMatrixCache + numOfSamples * numOfSelectPairs * 2,
                               sizeof(float_point) * numOfSamples * oldSize * 2,
                               cudaMemcpyDeviceToDevice));
    vector<vector<KeyValue> > computeSamples;
    for (int i = 0; i < numOfSelectPairs * 2; ++i) {
        computeSamples.push_back(subProblem.v_vSamples[workingSet[oldSize * 2 + i]]);
    }
    TIMER_START(preComputeTimer)
    //preCompute kernel values of new selected instances
    cusparseHandle_t handle;
    cusparseMatDescr_t descr;
    CSRMatrix workingSetMat(computeSamples, subProblem.getNumOfFeatures());
    float_point * devWSVal;
    int *devWSColInd;
    int *devWSRowPtr;
    float_point * devWSSelfDot;
    workingSetMat.copy2Dev(devWSVal, devWSRowPtr, devWSColInd, devWSSelfDot);
    SubHessianCalculator::prepareCSRContext(handle, descr);
    CSRMatrix::CSRmm2Dense(handle, CUSPARSE_OPERATION_NON_TRANSPOSE, CUSPARSE_OPERATION_TRANSPOSE, numOfSelectPairs * 2,
                           numOfSamples, subProblem.getNumOfFeatures(), descr,
                           workingSetMat.getNnz(), devWSVal, devWSRowPtr, devWSColInd, descr, nnz, devVal, devRowPtr,
                           devColInd, devHessianMatrixCache + numOfSamples * oldSize * 2);
    RBFKernel << < Ceil(numOfSelectPairs * 2 * numOfSamples, BLOCK_SIZE), BLOCK_SIZE >> > (devWSSelfDot, devSelfDot,
            devHessianMatrixCache + numOfSamples * oldSize * 2, numOfSelectPairs * 2, numOfSamples, param.gamma);
    SubHessianCalculator::releaseCSRContext(handle, descr);
    workingSetMat.freeDev(devWSVal, devWSRowPtr, devWSColInd, devWSSelfDot);
    TIMER_STOP(preComputeTimer)
}

