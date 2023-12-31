# Performance Permutation

#' @import graphics
# declare global variables (i.e. the foreach iterators)
globalVariables(c('p', 'fold'))

#' @title Monte Carlo Permutation of Model Performance
#' @description Applies Monte Carlo permutations to user specified models.  
#' The user can either use the results
#' from \code{fs.stability} or provide specified model parameters.
#' @param fs.model Object containing results from \code{fs.stability}
#' @param X A scaled matrix or dataframe containing numeric values of 
#' each feature
#' @param Y A factor vector containing group membership of samples
#' @param method A string of the model to be fit.
#' Available options are \code{"plsda"} (Partial Least Squares 
#' Discriminant Analysis),
#'  \code{"rf"} (Random Forest), \code{"gbm"} (Gradient Boosting Machine),
#'  \code{"svm"} (Support Vector Machines), \code{"glmnet"} 
#'  (Elastic-net Generalized Linear Model),
#'  and \code{"pam"} (Prediction Analysis of Microarrays)
#' @param k.folds How many and what fractions of dataset held-out for 
#' prediction (i.e. 3 = 1/3, 10 = 1/10, etc.)
#' @param metric Performance metric to assess.  Available options 
#' are \code{"Accuracy"}, \code{"Kappa"}, and \code{"ROC.AUC"}.
#' @param nperm Number of permutations, default \code{nperm = 10}
#' @param allowParallel Logical argument dictating if parallel processing 
#' is allowed via foreach package.  Default \code{allowParallel = FALSE}
#' @param create.plot Logical argument whether to create a distribution
#' plot of permuation results.
#' @param verbose Logical argument whether output printed automatically
#' in 'pretty' format.  Default \code{create.plot = FALSE}
#' @param ... Extra arguments that the user would like to apply to the models
#' @return \item{p.value}{Resulting p-value of permuation test}
#' @author Charles Determan Jr.
#' @references Guo Y., et. al. (2010) \emph{Sample size and statistical power 
#' considerations in high-dimensionality data settings: a comparative study 
#' of classification algorithms}. BMC Bioinformatics 11:447.
#' @example inst/examples/perm.class.R
#' @import DiscriMiner
#' @import randomForest
#' @import e1071
#' @import gbm
#' @import pamr
#' @import glmnet
#' @importFrom caret createMultiFolds
#' @importFrom permute shuffle
#' @export

perm.class <- 
  function(fs.model = NULL, 
           X, 
           Y, 
           method, 
           k.folds = 5, 
           metric = "Accuracy", 
           nperm = 10, 
           allowParallel = FALSE,
           create.plot = FALSE,
           verbose=TRUE,
           ...)
{
      
      assert_is_matrix(X)
      assert_is_numeric(X)
      assert_is_factor(Y)
      assert_is_character(method)
      assert_is_numeric(k.folds)
      assert_is_character(metric)
      # currently limiting to no more than 100,000 permutations
      assert_is_in_closed_range(nperm, 0, 100000)
      
      assert_is_logical(allowParallel)
      assert_is_logical(verbose)
      
      if(!method %in% modelList()$methods){
          stop("Method not recognized.  Check for method
                 code in 'modelList()'")
      }
      
    `%op%` <- if(allowParallel){
        `%dopar%` 
    }else{
        `%do%`
    } 
    
    theDots <- list(...)
    if(is.null(fs.model) & length(theDots) == 0){
        stop("Error: you must either provide fitted model from fs.stability 
            or the parameters for the desired model")
    }
    
    obsLevels <- levels(Y)
    
    data <- data.frame(X, .classes = Y)
    
    ## pam and will crash if there is a resample with <2 observations
    ## in a class. We will detect this and remove those classes.
    if(method == "pam")
    {
        yDist <- table(data$.classes)
        if(any(yDist < 2))
        {
          smallClasses <- names(yDist[yDist < 2])
          data <- data[!(data$.classes %in% smallClasses),]
        }
    }
    
    ## Factor the class labels
    levels(data$.classes) <- obsLevels
    xNames <- names(data)[!(names(data) %in% ".classes")]
    
    trainX <- X
    trainY <- Y
    nr <- nrow(trainX)
    
    if(method == "gbm" & length(obsLevels) == 2) {
        numClasses <- ifelse(data$.classes == obsLevels[1], 1, 0)
    }
    
    if(!is.null(fs.model)){
        args <- extract.args(fs.model, method)
    }else{
        if(!is.null(theDots) & length(theDots) != 0){
            args <- theDots
        }
    }
    
    if(!is.null(theDots) & length(theDots) != 0){
        if(names(theDots) %in% names(args)){
            arg.ind <- which(names(theDots) %in% names(args))
            args <- theDots[arg.ind]
            theDots <- theDots[-arg.ind]
        }  
    }
    
    args <- data.frame(do.call("cbind", args))
    names(args) <- lapply(names(args), FUN = function(x) paste(".", x, sep = ""))
    
    # for repeated cross-validation
    # creates a list of samples used for models
    inTrain <- createMultiFolds(trainY, k = k.folds, times = 1)
    
    # get the remaining samples for testing group
    outTrain <- lapply(inTrain, function(inTrain, total) total[-unique(inTrain)],
                     total = seq(nr))  
    
    # check if any only 1 index
    ind <- which(lapply(outTrain, length) == 1)
    # if only 1 index, randomly take one and add to outTrain
    if(length(ind) > 0){
        for(d in seq(along = ind)){
            move.ind <- sample(inTrain[[ind[d]]], 1)
            inTrain[[ind[d]]] <- inTrain[[ind[d]]][-move.ind]
            outTrain[[ind[d]]] <- sort(c(outTrain[[ind[d]]], move.ind))
        }
    }
    
    # extract new values of variables
    N <- nrow(trainX)
    perform <- foreach(p = seq.int(nperm+1),
                    .packages = c("OmicsMarkeR", 
                                  "foreach"),
                    .export = c("shuffle"),
                    .verbose = FALSE,
                    .errorhandling = "stop") %:%
        foreach(fold = seq(k.folds), # how many CV folds
                .combine = "c", 
                .verbose = FALSE, 
                .packages = c("OmicsMarkeR", "foreach"),
                .errorhandling = "stop") %op% 
{
    # permute group membership
    if(!p == 1){
    perm=shuffle(N)
    trainY <- trainY[perm]  
    }else{
    trainY <- trainY
    }
    
    ## combine variables and classes to make following functions simpler
    trainData <- as.data.frame(trainX)
    trainData$.classes <- trainY
    
    # create models
    mod <- try(
    training(data = trainData,
             method = method,
             tuneValue = args,
             obsLevels = obsLevels,
             theDots = theDots
    ),
    silent = TRUE)
    
    # calculate predictions if model fit successfully
    if(class(mod)[1] != "try-error")
    {          
    predicted <- try(
      predicting(method = method,
                 modelFit = mod$fit,
                 orig.data = trainData,
                 indicies = inTrain[[fold]],
                 newdata = trainData[outTrain[[fold]], 
                                     !(names(trainData) %in% ".classes"), 
                                     drop = FALSE],
                 param = args),
      silent = TRUE)
    
    # what should it do if predictionFunction fails???
    if(class(predicted)[1] == "try-error")
    {
      #stop("prediction results failed")
      stop(paste("prediction results failed on", 
                 method, " fold: ", fold, sep = " "))
    }
    
    # what should it do if createModel fails???
    } else {
        stop("model could not be fit")
    }
    
    if(is.list(predicted)){
        predicted <- as.vector(unlist(predicted))
    }
    
    predicted <- factor(as.character(predicted),
                      levels = obsLevels)
    tmp <- data.frame(pred = predicted,
                    obs = trainData$.classes[outTrain[[fold]]],
                    stringsAsFactors = FALSE)
    
    ## Set first column name to "pred"
    names(tmp)[1] <- "pred"
    
    ## Generate performance metrics
    perf.metrics <- perf.calc(tmp,
                            lev = obsLevels,
                            model = method)
    
    value <- perf.metrics[metric]
    value
}
 
  
    # extract p-value (one-tailed)
    perm.res <- sapply(perform, FUN = function(x) mean(x))  
    perm.p.val <- sprintf("%.3f", mean(
    as.numeric(
      round(sum(perm.res[2:(nperm+1)] >= perm.res[1]))/nperm, digits = 3)
    ))
    
    ###plot distribution of permutations results
    if(create.plot){
        plot(density(perm.res[2:(nperm+1)], 
                     from=min(perm.res)-sd(perm.res), 
                     to = max(perm.res)),
             xlab=paste(metric,"N=",nperm,sep=" "), 
             lwd=3, 
             col="steelblue", 
             main="Permutation Test")
        
        abline(v=perm.res[1], lwd=3, col='gold')
        legend("bottomleft", c(paste("perm.pval=", perm.p.val), sep=""))
    }
    
    if(verbose){
        cat("\nPermutation Results\n")
        cat(rep("-",20), sep="")
        cat("\n\n")
        cat(paste("Metric =", metric))
        cat(paste("\nP.Value =", perm.p.val))
    }
    
    perm.results = data.frame(p.value = perm.p.val)
    
    return(perm.results)
}







