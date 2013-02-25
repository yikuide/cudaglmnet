#include <stdlib.h>
#include <stdio.h>
#include <cublas.h>
#include <cuda.h>
#include <cmath>
#include <iostream>

#include <thrust/host_vector.h>
#include <thrust/device_vector.h>
#include <thrust/device_ptr.h>
#include <thrust/functional.h>
#include <thrust/transform_reduce.h>
#include <thrust/copy.h>
#include <thrust/fill.h>
#define index(i,j,ld) (((j)*(ld))+(i))

typedef struct {
    int n,p,num_lambda;
    thrust::host_vector<float> lambda;
    thrust::device_vector<float> X, y;
} data;

typedef struct {
    thrust::device_vector<float> beta, beta_old, theta, theta_old, momentum;
} coef;

typedef struct {
    float nLL;
    thrust::device_vector<float> eta, yhat, residuals, grad, U, diff_beta, diff_theta;
} opt;

typedef struct {
    int type, maxIt, reset;
    float gamma, t, thresh;
} misc;

struct square
{
    __host__ __device__
        float operator()(const float& x) const { 
            return x*x;
        }
};

struct soft_threshold
{
    const float lambda;

    soft_threshold(float _lambda) : lambda(_lambda) {}

    __host__ __device__
        float operator()(const float& x) const { 
            if (x > -lambda && x < lambda) return 0;
            else if (x > lambda) return x - lambda;
            else return x + lambda;
        }
};

struct saxpy
{
    const float a;

    saxpy(float _a) : a(_a) {}

    __host__ __device__
        float operator()(const float& x, const float& y) const { 
            return a * x + y;
        }
};

struct absolute_value
{
    __host__ __device__
        float operator()(const float& x) const { 
            if (x < 0) return (-1*x);
            else return x;
        }
};


  
extern "C"{


void activePathSol(float*, float*, int*, int*, float*, int*,
                   int*, float*, int*, float*, float*,
                   float*, int*);
void init(data*, coef*, opt*, misc*,
          float*, float*, int, int, float*, int,
          int, float*, int, float, float,
          float, int);
void pathSol(data* ddata, coef* dcoef, opt* dopt, misc* dmisc, float* beta);
void singleSolve(data* ddata, coef* dcoef, opt* dopt, misc* dmisc, int j);
float calcNegLL(data* ddata, coef* dcoef, opt* dopt, misc* dmisc, thrust::device_vector<float> pvector, int j);
void gradStep(data* ddata, coef* dcoef, opt* dopt, misc* dmisc, int j);
void proxCalc(data* ddata, coef* dcoef, opt* dopt, misc* dmisc, int j);
void nestStep(data* ddata, coef* dcoef, opt* dopt, misc* dmisc, int j, int iter);
int checkStep(data* ddata, coef* dcoef, opt* dopt, misc* dmisc, int j);
int checkCrit(data* ddata, coef* dcoef, opt* dopt, misc* dmisc, int j, int iter);
void shutdown(data* ddata, coef* dcoef, opt* dopt, misc* dmisc);
float device_vector2Norm(thrust::device_vector<float> x);
float device_vectorDot(thrust::device_vector<float> x,
                       thrust::device_vector<float> y);
float device_vectorMaxNorm(thrust::device_vector<float> x);
void device_vectorSoftThreshold(thrust::device_vector<float> x, thrust::device_vector<float>, float lambda);
void device_vectorSgemv(thrust::device_vector<float> A,
                          thrust::device_vector<float> x,
                          thrust::device_vector<float> b,
                          int n, int p);
void device_vectorCrossProd(thrust::device_vector<float> X,
                              thrust::device_vector<float> y,
                              thrust::device_vector<float> b,
                              int n, int p);
thrust::device_vector<float> makeDeviceVector(float* x, int size);
thrust::device_vector<float> makeEmptyDeviceVector(int size);
 


  /*
    Entry point for R
    X is a matrix (represented as a 1d array) that is n by p
    y is a vector that is n by 1
  */
  void activePathSol(float* X, float* y, int* n, int* p, float* lambda, int* num_lambda,
                     int* type, float* beta, int* maxIt, float* thresh, float* gamma,
                     float* t, int* reset)
  { 
    //setup pointers
    data* ddata = (data*)malloc(sizeof(data));
    coef* dcoef = (coef*)malloc(sizeof(coef));
    opt* dopt = (opt*)malloc(sizeof(opt));
    misc* dmisc = (misc*)malloc(sizeof(misc));
 
    //allocate pointers, init cublas
    init(ddata, dcoef, dopt, dmisc,
         X, y, n[0], p[0], lambda, num_lambda[0],
         type[0], beta, maxIt[0], thresh[0], gamma[0],
         t[0], reset[0]);

    //solve
    pathSol(ddata, dcoef, dopt, dmisc, beta);

    //shutdown
    shutdown(ddata, dcoef, dopt, dmisc);
  }

  void init(data* ddata, coef* dcoef, opt* dopt, misc* dmisc,
            float* X, float* y, int n, int p, float* lambda, int num_lambda,
            int type, float* beta, int maxIt, float thresh, float gamma,
            float t, int reset)
  {
    cublasInit();

    /* Set data variables */

    ddata->X = makeDeviceVector(X, n*p);
    ddata->y = makeDeviceVector(y, n);
    ddata->lambda = thrust::host_vector<float>(lambda, lambda+num_lambda);
    ddata->n = n;
    ddata->p = p;
    ddata->num_lambda = num_lambda;

    /* Set coef variables */

    dcoef->beta = makeEmptyDeviceVector(p);
    dcoef->beta_old = makeEmptyDeviceVector(p);
    dcoef->theta = makeEmptyDeviceVector(p);
    dcoef->theta_old = makeEmptyDeviceVector(p);
    dcoef->momentum = makeEmptyDeviceVector(p);

    /* Set optimization variables */

    dopt->eta = makeEmptyDeviceVector(p);
    dopt->yhat = makeEmptyDeviceVector(n);
    dopt->residuals = makeEmptyDeviceVector(n);
    dopt->grad = makeEmptyDeviceVector(p);
    dopt->U = makeEmptyDeviceVector(p);
    dopt->diff_beta = makeEmptyDeviceVector(p);
    dopt->diff_theta = makeEmptyDeviceVector(p);

    /* Set misc variables */

    dmisc->type = type;
    dmisc->maxIt = maxIt;
    dmisc->gamma = gamma;
    dmisc->t = t;
    dmisc->reset = reset;
    dmisc->thresh = thresh;
  }

  void pathSol(data* ddata, coef* dcoef, opt* dopt, misc* dmisc, float* beta)
  {
    int j = 0;
    for (j=0; j < ddata->num_lambda; j++){
      dcoef->beta_old = dcoef->beta;
      dcoef->theta_old = dcoef->theta;
      singleSolve(ddata, dcoef, dopt, dmisc, j);

      int startIndex = j*ddata->p;
      int i = 0;
      for(i=0; i < ddata->p; i++){
        beta[startIndex+i] = dcoef->beta[i];
      }
    }
  }

  void singleSolve(data* ddata, coef* dcoef, opt* dopt, misc* dmisc, int j)
  {
    int iter = 0;
    while (checkCrit(ddata, dcoef, dopt, dmisc, j, iter) == 0)
    {
      calcNegLL(ddata, dcoef, dopt, dmisc, dcoef->beta, j);
      while (checkStep(ddata, dcoef, dopt, dmisc, j) == 0)
      {
        gradStep(ddata, dcoef, dopt, dmisc, j);
      }
      nestStep(ddata, dcoef, dopt, dmisc, j, iter);
      iter = iter + 1;
    }
  }

  float calcNegLL(data* ddata, coef* dcoef, opt* dopt, misc* dmisc,
                  thrust::device_vector<float> pvector, int j)
  {
    device_vectorSgemv(ddata->X, pvector, dopt->eta, ddata->n, ddata->p);
    switch (dmisc->type)
    {
      case 0:  //normal
      {
        dopt->nLL = 0.5 * device_vector2Norm(dopt->residuals);
        break;
      }
      default:  //default to normal
      { 
        dopt->nLL = 0.5 * device_vector2Norm(dopt->residuals);
        break;
      }
    }
    return dopt->nLL;
  }

  void gradStep(data* ddata, coef* dcoef, opt* dopt, misc* dmisc, int j)
  {
    switch (dmisc->type)
    {
      case 0:  //normal
      {
        //yhat = XB
        device_vectorSgemv(ddata->X, dcoef->beta, dopt->yhat, ddata->n, ddata->p);
        //residuals = y - yhat
        thrust::transform(ddata->y.begin(), ddata->y.end(),
                          dopt->yhat.begin(),
                          dopt->residuals.begin(),
                          thrust::minus<float>());
        //grad = X^T residuals
        device_vectorCrossProd(ddata->X, dopt->residuals, dopt->grad, ddata->n, ddata->p);
        //U = -t * grad + beta
        thrust::transform(dopt->grad.begin(), dopt->grad.end(),
                          dcoef->beta.begin(),
                          dopt->U.begin(),
                          saxpy(-dmisc->t));
        proxCalc(ddata, dcoef, dopt, dmisc, j);
        break;
      }
      default:
      {
        break;
      }
    } 
  }

  void proxCalc(data* ddata, coef* dcoef, opt* dopt, misc* dmisc, int j)
  {
    switch (dmisc->type)
    {
      case 0:  //normal
      {
        device_vectorSoftThreshold(dopt->U, dcoef->theta, ddata->lambda[j] * dmisc->t);
        break;
      }
      default:
      {
        break;
      }
    }
  }

  void nestStep(data* ddata, coef* dcoef, opt* dopt, misc* dmisc, int j, int iter)
  {
    dcoef->beta_old = dcoef->beta;
    //momentum = theta - theta old
    thrust::transform(dcoef->theta.begin(), dcoef->theta.end(),
                      dcoef->theta_old.begin(),
                      dcoef->momentum.begin(),
                      thrust::minus<float>());
    float scale = (float) (iter % dmisc->reset) / (iter % dmisc->reset + 3);
    //beta = theta + scale*momentum
    thrust::transform(dcoef->momentum.begin(), dcoef->momentum.end(),
                      dcoef->theta.begin(),
                      dcoef->beta.begin(),
                      saxpy(scale));
    dcoef->theta_old = dcoef->theta;
  }

  int checkStep(data* ddata, coef* dcoef, opt* dopt, misc* dmisc, int j)
  {
    float nLL = calcNegLL(ddata, dcoef, dopt, dmisc, dcoef->theta, j);
    //iprod is the dot product of diff and grad
    float iprod = device_vectorDot(dopt->diff_theta, dopt->grad);
    float sumSquareDiff = device_vector2Norm(dopt->diff_theta);

    int check = (int)(nLL < (dopt->nLL + iprod + sumSquareDiff) / (2 * dmisc->t));
    if (check == 0) dmisc->t = dmisc->t * dmisc->gamma;
      
    return check;
  }

  int checkCrit(data* ddata, coef* dcoef, opt* dopt, misc* dmisc, int j, int iter)
  {
    if (iter > dmisc->maxIt) return 1;
    else return 0;
    /*float move = device_vectorMaxNorm(dopt->diff_theta);  
    if ((iter > dmisc->maxIt) || (move < dmisc->thresh)) return 1;
    else return 0;*/
  }

  void shutdown(data* ddata, coef* dcoef, opt* dopt, misc* dmisc)
  {
    //free(ddata); free(dcoef); free(dopt); free(dmisc);
    cublasShutdown();
  }

  /*
    MISC MATH FUNCTIONS
  */

  thrust::device_vector<float> makeDeviceVector(float* x, int size)
  {
    return thrust::device_vector<float> (x, x+size);
  }

  thrust::device_vector<float> makeEmptyDeviceVector(int size)
  {
    thrust::host_vector<float> x(size, 0);
    thrust::device_vector<float> dx = x;
    return dx;
  }

  // ||x||_max
  float device_vectorMaxNorm(thrust::device_vector<float> x)
  {
    return thrust::transform_reduce(x.begin(), x.end(),
                                    absolute_value(), 0.0, thrust::maximum<float>());  
  }

  // ||x||_2^2
  float device_vector2Norm(thrust::device_vector<float> x)
  {  
    return cublasSnrm2(x.size(), thrust::raw_pointer_cast(&x[0]), 1);
  }

  float device_vectorDot(thrust::device_vector<float> x,
                         thrust::device_vector<float> y)
  {  
    return cublasSdot(x.size(), thrust::raw_pointer_cast(&x[0]), 1,
                      thrust::raw_pointer_cast(&y[0]), 1);
  }

  // b = X^T y
  void device_vectorCrossProd(thrust::device_vector<float> X,
                              thrust::device_vector<float> y,
                              thrust::device_vector<float> b,
                              int n, int p)
  {
    cublasSgemv('t', n, p, 1,
                thrust::raw_pointer_cast(&X[0]), n,
                thrust::raw_pointer_cast(&y[0]), 1,
                0, thrust::raw_pointer_cast(&b[0]), 1); 
  }

  // b = Ax
  void device_vectorSgemv(thrust::device_vector<float> A,
                          thrust::device_vector<float> x,
                          thrust::device_vector<float> b,
                          int n, int p)
  {
    cublasSgemv('n', n, p, 1,
                thrust::raw_pointer_cast(&A[0]), n,
                thrust::raw_pointer_cast(&x[0]), 1,
                0, thrust::raw_pointer_cast(&b[0]), 1);
  }

  // S(x, lambda)
  void device_vectorSoftThreshold(thrust::device_vector<float> x,
                                  thrust::device_vector<float> dest,
                                  float lambda)
  {
    thrust::transform(x.begin(), x.end(), dest.begin(), soft_threshold(lambda));
  }

}

int main() {
  thrust::host_vector<float> X(1000,1);
  thrust::host_vector<float> y(100,1);
  thrust::host_vector<float> beta(10,1);

  int n = 100;
  int p = 10;
  float lambda = 1;
  int num_lambda = 1;
  int type = 0;
  int maxIt = 10;
  float thresh = 0.001;
  float gamma = 0.001;
  float t = 0.1;
  int reset = 5;

  activePathSol(&X[0], &y[0], &n, &p, &lambda, &num_lambda,
                &type, &beta[0], &maxIt, &thresh, &gamma,
                &t, &reset);
  return 0;
}
