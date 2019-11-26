/*
 ============================================================================
 Name        : CUDA_ANN.cu
 Author      : federico
 Version     :
 Copyright   : Your copyright notice
 Description : CUDA Approximate Nearest Neighbors
 ============================================================================
 */

#include <sstream>
#include <iterator>
#include <iostream>
#include <vector>
#include <chrono>
#include <omp.h>
#include <unistd.h>

#ifdef __CUDACC__
#include <cuda.h>
#endif

#include "utils.cpp"
#include "read_sift_dataset.cpp"
#include "search.hpp"
#include "csvfile.h"
#ifdef __CUDACC__
#include "search.cuh"
#endif


/** @brief Evaluate a search algorithm.
  * @param s: search algorithm to evaluate
  * @param queries: samples to search
  * @param groundTruth: for each query, ordered vector of indexes that should return the search method
  * @param numResults: number of queries to make
  * @param mustCheckCorrectness: if true, assures that results of the search are the same of groundTruth
  * @return elapsed time to search for all queries
  *
  * This method evaluates the time needed to a search algorithm to search for all queries in a dataset.
  * The search algorithm must be previously initialized on a dataset.
  */
template <typename T>
std::chrono::duration<double> evaluate(Search<T> *s, T* queries, std::vector <std::vector<int>> &groundTruth, const int &numQueries, int &numResults, bool mustCheckCorrectness = false);
// TODO cambiare signature di questa funzione: il groundTruth non è necessario quando non si vuole anche controllare la correttezza dell'algoritmo

/** @brief Check for correcteness
  * @param groundTruth: for each query, ordered vector of indexes that should return the search method
  * @param nnAllIndexes: for each query, vector of indexes returned by the search method
  * @param nnAllDistancesSqr: for each query, squared euclidean distance between the query point and every its neighbor
  * @return true if given indexes and distances are coherent to the groundTruth
  *
  * This method evaluates if the results of the search algorithm are coherent to the groundTruth.
  */
template <typename T>
bool checkCorrectness(std::vector< std::vector<int> > &groundTruth, std::vector<std::vector<int> > &nnAllIndexes, std::vector<std::vector<T> > &nnAllDistancesSqr);

/** Execute the experiments
  */
int main(int argc, char **argv) {
    #ifdef _OPENMP
        std::cout << "_OPENMP defined" << std::endl;
    #endif
    // TODO prendere i parametri per gli esperimenti da riga di comando

    std::string dataFolder = "../data";
    char opt;
    while ((opt = getopt(argc, argv, "d:")) != -1) {
        switch (opt) {
            case 'd':
                dataFolder = optarg;
                break;
            default: /* '?' */
                fprintf(stderr, "Usage: %s [-d path_to_data_folder]\n", argv[0]);
                exit(EXIT_FAILURE);
        }
    }

    std::cout << "reading dataset in: " << dataFolder << std::endl;

    //// files path definition
    // 10^6 examples dataset:
    std::string baseFileName = "/sift/sift_base.fvecs";
    std::string groundtruthFileName = "/sift/sift_groundtruth.ivecs";
    std::string queryFileName = "/sift/sift_query.fvecs";
    // 10^4 examples dataset:
//    std::string baseFileName = "../data/siftsmall/siftsmall_base.fvecs";
//    std::string groundtruthFileName = "../data/siftsmall/siftsmall_groundtruth.ivecs";
//    std::string queryFileName = "../data/siftsmall/siftsmall_query.fvecs";

    //// evaluation parameters
    int numResults = 100;

    //// data structures for dataset
    std::vector<std::vector<float> > host_dataset_vv;      // datasetSize x spaceDim       <- dataset where to find nearest neighbors
    std::vector<std::vector<float> > host_queries_vv;      // numQueries  x spaceDim       <- test samples
    std::vector<std::vector<int> > host_grTruth_vv;        // numQueries  x 100            <- first 100 nearest neighbors for each test sample

    //// reading of dataset, queries and groundtruth
    std::cout << "Reading dataset" << std::endl;
    // TODO safely join paths dataFolder and ... (provare con libreria boost)
    assert((readVecsFile<float, float>(dataFolder + baseFileName, host_dataset_vv, true)));
    std::cout << "Reading queries" << std::endl;
    assert((readVecsFile<float, float>(dataFolder + queryFileName, host_queries_vv, true)));
    std::cout << "Reading groundtruth for queries" << std::endl;
    assert((readVecsFile<int, int>(dataFolder + groundtruthFileName, host_grTruth_vv, true)));

    // dataset slice (to do quick tests) TODO remove in final version
//    const int numExamples = 30000;
//    host_dataset_vv = std::vector< std::vector<float> >(host_dataset_vv.begin(), host_dataset_vv.begin() + numExamples);
//    host_dataset_vv.resize(numExamples);

    //// constants initialization
    const int datasetSize = static_cast<const int>(host_dataset_vv.size());
    std::cout << "Dataset size: " << datasetSize << std::endl;

    std::cout << "Space size: " << host_dataset_vv.at(0).size() << std::endl;
    const int spaceDim = 128; //FIXME problem whit release mode if I use  spaceDim = host_dataset_vv[0].size(); why?

    const int numQueries = static_cast<const int>(host_queries_vv.size());
    std::cout << "Number of queries: " << host_dataset_vv.size() << std::endl;

    assert(datasetSize > 0);
    assert(spaceDim > 0);
    assert(numQueries > 0);
    assert(host_queries_vv.size() == host_grTruth_vv.size());          // host_queries_vv and host_grTruth_vv must have same length
    assert(numResults <= host_grTruth_vv.at(0).size());            // assert(numResults <= 100)

    //// some print to understand data
    //dataPrint(host_dataset_vv, host_grTruth_vv, host_queries_vv);
//    for(int i=0; i<host_grTruth_vv.size(); i++)
//        for(int j=0; j<host_grTruth_vv[0].size(); j++)
//            if(!(host_grTruth_vv[i][j] >= 0 && host_grTruth_vv[i][j] < datasetSize))
//            	cout << "ERRORE: "<< i << " " << j<< " "<< host_grTruth_vv[i][j] << std::endl;


    //// data conversion
    // convert queries from vector of vectors into raw pointer
    // TODO capire perché con la pinned va più lento mentre invece dovrebbe essere più veloce (forse perché il dato trasferito è piccolo, ogni query è 512 byte)
    float *host_queries_ptr;
//    CUDA_CHECK_RETURN(
//            cudaMallocHost((void ** )&host_queries_ptr, sizeof(float) * numQueries * spaceDim)     // allocate pinned memory on host RAM: it allows the use of DMA, speeding up cudaMemcpy
//    );
    host_queries_ptr = new float[numQueries * spaceDim]; // non-pinned memory
    for (int i = 0; i < numQueries; i++) {
        // move i-th query from vector of vectors to raw pointer
        std::memcpy(host_queries_ptr + (i * spaceDim), &host_queries_vv[i][0], sizeof(float) * spaceDim);
    }

    //// evaluation: for each implementation, execute search and measure elapsed time
    Search<float> *s;
    auto start = std::chrono::high_resolution_clock::now();
    //// CPU evaluation
    int maxThreads = 1;
#ifdef _OPENMP
    maxThreads = omp_get_max_threads();
#endif
    try // I use this for found a exception on csv
    {   // THE CVS FILE IS CREATED INTO THE CMAKE-BUILD-DEBUG OR CMAKE-BUILD-RELEASE FOLDER !!!!!!!!!!
        // TODO THE CSV FILE IS CREATED EVERY TIME WHEN I EXECUTE THE PROGRAM AND I WANT TO APPEND THE NEW CSV WHIT NEW EXPERIMENT
        csvfile csv("Experiment.csv"); // throws exceptions!
        // Hearer
        csv << "num_threads" << "dataset_size" << "init time" << "eval time" << "time (init+eval)" << "processor" << endrow;
        // Data example
        // csv <<  "seq" << 0 << 1000 << 0.5 << 0.5 << 1 <<"Intel Core i7-9750H" << endrow;

        for(int numCores = 1; numCores <= maxThreads; numCores++){  // openmp directive for the number of cores
            //TODO add the command for create a csv here like " alg_version;num_threads;dataset_size;time;name "
            std::cout << "Test on CPU, cores: " << numCores << std::endl;
            start = std::chrono::high_resolution_clock::now();
            s = new CpuSearch<float>(host_dataset_vv, numCores);
            std::chrono::duration<double> cpuInitTime = std::chrono::high_resolution_clock::now() - start;
            std::chrono::duration<double> cpuEvalTime = evaluate<float>(s, host_queries_ptr, host_grTruth_vv, numQueries, numResults, true);
            std::cout << "CPU (Cores:" << numCores << ") init time: " << cpuInitTime.count() << std::endl;
            std::cout << "CPU (Cores:" << numCores << ") eval time: " << cpuEvalTime.count() << std::endl;
            csv << numCores << datasetSize << cpuInitTime.count() << cpuEvalTime.count() << cpuInitTime.count() + cpuEvalTime.count() << "processore" << endrow;
            delete s;
        }
        //// GPU evaluation
        #ifdef __CUDACC__
            start = std::chrono::high_resolution_clock::now();
            s = new CudaSearch<float>(host_dataset_vv);
            std::chrono::duration<double> gpuInitTime = std::chrono::high_resolution_clock::now() - start;
            std::chrono::duration<double> gpuEvalTime = evaluate<float>(s, host_queries_ptr, host_grTruth_vv, numQueries, numResults, true);
            std::cout << "GPU init time: " << gpuInitTime.count() << std::endl;
            std::cout << "GPU eval time: " << gpuEvalTime.count() << std::endl;
            delete s;
        #endif
    }
    catch (const std::exception &ex)
    {
        std::cout << "Exception was thrown: " << ex.what() << std::endl;
    }
    // TODO dentro (o dopo) ogni search, salvare risultati su file csv

    delete [] host_queries_ptr;

	return 0;
}

template <typename T>
std::chrono::duration<double> evaluate(Search<T> *s, T* queries_ptr, std::vector <std::vector<int>> &groundTruth, const int &numQueries, int &numResults, bool mustCheckCorrectness){

    //// data structures for query
    std::vector<std::vector<int> > nnAllIndexes(numQueries, std::vector<int>(numResults));    // numQueries x numResults
    std::vector<std::vector<T> > nnAllDistancesSqr(numQueries, std::vector<float>(numResults));     // numQueries x numResults

    // measure time of execution of all queries

    auto start = std::chrono::high_resolution_clock::now();
    int sd = s->getSpaceDim();
    for(int i = 0; i < numQueries; i++){
        s->search(&queries_ptr[i * sd], nnAllIndexes[i], nnAllDistancesSqr[i], numResults);
        //std::cout << vecToStr(nnAllDistancesSqr[i]) << std::endl;
    }
    auto end = std::chrono::high_resolution_clock::now();
    std::chrono::duration<double> elapsedTime = end-start;

    // eventually check for correctness
    if(mustCheckCorrectness) {
        //assert(checkCorrectness(groundTruth, nnAllIndexes, nnAllDistancesSqr));
        bool c = checkCorrectness(groundTruth, nnAllIndexes, nnAllDistancesSqr);
        std::cout << "correctness: " << (c?"true":"false") << std::endl;
    }

    return elapsedTime;
}

template <typename T>
bool checkCorrectness(std::vector< std::vector<int> > &groundTruth, std::vector<std::vector<int> > &nnAllIndexes, std::vector<std::vector<T> > &nnAllDistancesSqr){
    for(int i = 0; i < nnAllIndexes.size(); i++){
        //std::cout << "\nelement " << i << " of vector groundtruth (" << groundTruth[i].size() << " elements):\n\t" << vecToStr<int>(groundTruth[i]) << std::endl;
        //std::cout << "\nelement " << i << " of vector nnAllIndexes (" << nnAllIndexes[i].size() << " elements):\n\t" << vecToStr<int>(nnAllIndexes[i]) << std::endl;
        if(!checkKNN<float>(groundTruth[i], nnAllIndexes[i], nnAllDistancesSqr[i]))
            return false;
    }
    return true;
}