#' Cross Validation
#' 
#' The cross valudation function of xgboost
#' 
#' @importFrom data.table data.table
#' @importFrom data.table as.data.table
#' @importFrom magrittr %>%
#' @importFrom data.table :=
#' @importFrom data.table rbindlist
#' @importFrom stringr str_extract_all
#' @importFrom stringr str_extract
#' @importFrom stringr str_split
#' @importFrom stringr str_replace
#' @importFrom stringr str_match
#' 
#' @param params the list of parameters. Commonly used ones are:
#' \itemize{
#'   \item \code{objective} objective function, common ones are
#'   \itemize{
#'     \item \code{reg:linear} linear regression
#'     \item \code{binary:logistic} logistic regression for classification
#'   }
#'   \item \code{eta} step size of each boosting step
#'   \item \code{max.depth} maximum depth of the tree
#'   \item \code{nthread} number of thread used in training, if not set, all threads are used
#' }
#'
#'   See \link{xgb.train} for further details.
#'   See also demo/ for walkthrough example in R.
#' @param data takes an \code{xgb.DMatrix} or \code{Matrix} as the input.
#' @param nrounds the max number of iterations
#' @param nfold the original dataset is randomly partitioned into \code{nfold} equal size subsamples. 
#' @param label option field, when data is \code{Matrix}
#' @param missing Missing is only used when input is dense matrix, pick a float
#'     value that represents missing value. Sometime a data use 0 or other extreme value to represents missing values.
#' @param prediction A logical value indicating whether to return the prediction vector.
#' @param showsd \code{boolean}, whether show standard deviation of cross validation
#' @param metrics, list of evaluation metrics to be used in corss validation,
#'   when it is not specified, the evaluation metric is chosen according to objective function.
#'   Possible options are:
#' \itemize{
#'   \item \code{error} binary classification error rate
#'   \item \code{rmse} Rooted mean square error
#'   \item \code{logloss} negative log-likelihood function
#'   \item \code{auc} Area under curve
#'   \item \code{merror} Exact matching error, used to evaluate multi-class classification
#' }
#' @param obj customized objective function. Returns gradient and second order 
#'   gradient with given prediction and dtrain, 
#' @param feval custimized evaluation function. Returns 
#'   \code{list(metric='metric-name', value='metric-value')} with given 
#'   prediction and dtrain,
#' @param verbose \code{boolean}, print the statistics during the process.
#' @param ... other parameters to pass to \code{params}.
#' 
#' @return A \code{data.table} with each mean and standard deviation stat for training set and test set.
#' 
#' @details 
#' The original sample is randomly partitioned into \code{nfold} equal size subsamples. 
#' 
#' Of the \code{nfold} subsamples, a single subsample is retained as the validation data for testing the model, and the remaining \code{nfold - 1} subsamples are used as training data. 
#' 
#' The cross-validation process is then repeated \code{nrounds} times, with each of the \code{nfold} subsamples used exactly once as the validation data.
#' 
#' All observations are used for both training and validation.
#' 
#' Adapted from \url{http://en.wikipedia.org/wiki/Cross-validation_\%28statistics\%29#k-fold_cross-validation}
#'
#' @examples
#' data(agaricus.train, package='xgboost')
#' dtrain <- xgb.DMatrix(agaricus.train$data, label = agaricus.train$label)
#' history <- xgb.cv(data = dtrain, nround=3, nthread = 2, nfold = 5, metrics=list("rmse","auc"),
#'                   max.depth =3, eta = 1, objective = "binary:logistic")
#' print(history)
#' @export
#'
xgb.cv <- function(params=list(), data, nrounds, nfold, label = NULL, missing = NULL, 
                   prediction = FALSE, showsd = TRUE, metrics=list(), 
                   obj = NULL, feval = NULL, verbose = T,...) {
  if (typeof(params) != "list") {
    stop("xgb.cv: first argument params must be list")
  }
  if (nfold <= 1) {
    stop("nfold must be bigger than 1")
  }
  if (is.null(missing)) {
    dtrain <- xgb.get.DMatrix(data, label)
  } else {
    dtrain <- xgb.get.DMatrix(data, label, missing)
  }
  params <- append(params, list(...))
  params <- append(params, list(silent=1))
  for (mc in metrics) {
    params <- append(params, list("eval_metric"=mc))
  }

  folds <- xgb.cv.mknfold(dtrain, nfold, params)
  obj_type = params[['objective']]
  mat_pred = FALSE
  if (!is.null(obj_type) && obj_type=='multi:softprob')
  {
    num_class = params[['num_class']]
    if (is.null(num_class))
      stop('must set num_class to use softmax')
    predictValues <- matrix(0,xgb.numrow(dtrain),num_class)
    mat_pred = TRUE
  }
  else
    predictValues <- rep(0,xgb.numrow(dtrain))
  history <- c()
  for (i in 1:nrounds) {
    msg <- list()
    for (k in 1:nfold) {
      fd <- folds[[k]]
      succ <- xgb.iter.update(fd$booster, fd$dtrain, i - 1, obj)
      if (i<nrounds) {
          msg[[k]] <- xgb.iter.eval(fd$booster, fd$watchlist, i - 1, feval) %>% str_split("\t") %>% .[[1]]
      } else {
        if (!prediction) {
          msg[[k]] <- xgb.iter.eval(fd$booster, fd$watchlist, i - 1, feval) %>% str_split("\t") %>% .[[1]]
        } else {
          res <- xgb.iter.eval(fd$booster, fd$watchlist, i - 1, feval, prediction)
          if (mat_pred) {
            pred_mat = matrix(res[[2]],num_class,length(fd$index))
            predictValues[fd$index,] <- t(pred_mat)
          } else {
            predictValues[fd$index] <- res[[2]]
          }
          msg[[k]] <- res[[1]] %>% str_split("\t") %>% .[[1]]
        }
      }
    }
    ret <- xgb.cv.aggcv(msg, showsd)
    history <- c(history, ret)
    if(verbose) paste(ret, "\n", sep="") %>% cat
  }
  
  colnames <- str_split(string = history[1], pattern = "\t")[[1]] %>% .[2:length(.)] %>% str_extract(".*:") %>% str_replace(":","") %>% str_replace("-", ".")
  colnamesMean <- paste(colnames, "mean")
  if(showsd) colnamesStd <- paste(colnames, "std")
  
  colnames <- c()
  if(showsd) for(i in 1:length(colnamesMean)) colnames <- c(colnames, colnamesMean[i], colnamesStd[i])
  else colnames <- colnamesMean
  
  type <- rep(x = "numeric", times = length(colnames))
  dt <- read.table(text = "", colClasses = type, col.names = colnames) %>% as.data.table
  split <- str_split(string = history, pattern = "\t")
  
  for(line in split) dt <- line[2:length(line)] %>% str_extract_all(pattern = "\\d*\\.+\\d*") %>% unlist %>% as.list %>% {vec <- .; rbindlist(list(dt, vec), use.names = F, fill = F)}
  
  if (prediction) {
    return(list(dt = dt,pred = predictValues))
  }
  return(dt)
}

# Avoid error messages during CRAN check.
# The reason is that these variables are never declared
# They are mainly column names inferred by Data.table...
globalVariables(".")
