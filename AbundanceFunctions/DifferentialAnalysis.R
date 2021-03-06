################################################################################
# Functions involved in ratio formation and regression analyses
#
# lmPval           --- matricized multi-response linear regression significance
# regressMatrix    --- estimate treatment effects in data matrices
# designRatios     --- calculate groupwise ratios and select feature masks
#
################################################################################


lmPval <-
function(lm.obj){
  # T-test p-value calculation for each parameter's estimated coefficient
  #  for each response in linear regression output from lm()
  # lm.obj: object returned by lm, class "lm" or "mlm"
  # Code adapted from summary.lm

  # test: is lm.obj an output from lm()?
  if (is.null(lm.obj$terms) || is.null(lm.obj$qr)) {
    stop("Invalid 'lm' object:  no 'terms' or 'qr' component") }
  if (is.na(lm.obj$df.residual) ||
    (nrow(lm.obj$qr$qr) - lm.obj$rank) != lm.obj$df.residual) {
    warning("Residual degrees of freedom in object suggest this is not an \"lm\" fit") }
  if (lm.obj$rank==0) {
    stop("Regression rank zero: no significance to calculate") }

  # test: one response or many?
  m = !is.null(dim(lm.obj$coefficients))

  # extract statistics from lm() output
  p = lm.obj$rank
  Qr = lm.obj$qr
  f = lm.obj$fitted.values
  r = lm.obj$residuals
  rdf = lm.obj$df.residual
  w = lm.obj$weights

  # calculate proportion of variation explained by model
  if(m){ # multiple responses
    if( is.null(w) ){ # non-weighted regression
      mss = if( attr(lm.obj$terms, "intercept")){
        colSums( (f - matrix(nrow=nrow(f),ncol=ncol(f),data=colMeans(f),byrow=T))^2 )
        } else { colSums( f^2 ) }
      rss =  colSums(r^2)
    } else { # weighted regression
      mss = if( attr(lm.obj$terms, "intercept")){
        colSums(w * (f - matrix(nrow=nrow(f),ncol=ncol(f),data=colSums(w * f/colSums(w)),byrow=T)  )^2 )
      } else {
        colSums(w * f^2)}
      rss = colSums(w * r^2)
      r = sqrt(w) * r
    }
  } else { # single response
    if( is.null(w) ){ # non-weighted regression
      mss = if( attr(lm.obj$terms, "intercept")){ sum( (f - mean(f))^2 )
        } else { sum( f^2 ) }
      rss =  sum(r^2)
    } else { # weighted regression
      mss = if( attr(lm.obj$terms, "intercept")){
        sum(w * (f - sum(w * f/sum(w)))^2 )
      } else {
        sum(w * f^2)}
      rss = sum(w * r^2)
      r = sqrt(w) * r
    }
  }
  resvar = rss/rdf

  # calculate squared error per parameter
  p1 = 1:p
  R = chol2inv(Qr$qr[p1, p1, drop = FALSE])
  se = if(m){
    # matrix resvar for proper output dimensions
    # in case of square data, default elementwise vector * matrix is bycol
    #  as required here
    sqrt( diag(R) * matrix(nrow=p,ncol=length(rss),data=resvar,byrow=T) )

  }else{ sqrt( diag(R) * resvar ) }

  # calculate T-statistics and p-values from coefficient estimates and SE
  est = if(m){ lm.obj$coefficients[Qr$pivot[p1],] }
  else{ lm.obj$coefficients[Qr$pivot[p1]] }
  tval = est/se
  pval =  2 * pt(abs(tval), rdf, lower.tail = FALSE)

  # calculate overall model performance
  if( p == attr(lm.obj$terms, "intercept") ){ #only intercept parameter
    r.squared = adj.r.squared = 0
  }else{
    df.int = if( attr(lm.obj$terms,"intercept")){ 1 } else { 0 }
    r.squared = mss / (mss + rss)
    adj.r.squared = 1 - (1-r.squared)*( (nrow(Qr$qr)-df.int)/rdf )
    f.statistic = (mss/(p - df.int))/resvar
    f.df = p - df.int; f.dendf = rdf
    p.F = pf(f.statistic, f.df, f.dendf, lower.tail=F)
  }

  # collect variables to return
  if(m){
    ans = list(pval=I(pval), r.squared=r.squared, adj.r.squared=adj.r.squared, p.F=p.F, f.statistic=f.statistic, f.df=f.df, f.dendf=f.dendf)
  } else {
    ans = list(pval=pval, r.squared=r.squared, adj.r.squared=adj.r.squared, p.F=p.F, f.statistic=f.statistic, f.df=f.df, f.dendf=f.dendf)
  }
  return(ans)
}
regressMatrix <-
function(normmat, expt.design, lm_expression, 
                         response_var="y", contr_list=NULL,
                         plotdata = NULL, plot2file = FALSE, histbins = 40
                         ){
  # function to run linear regression on multiresponse data matrix with given model and optional contrasts
  # Arguments
  # normmat: a matrix of normalized (sample-bias-reduced) abundance data
  #  !! All rows containing NAs MUST be removed before running regression !!
  #  rownames are unique identifiers for features measured per row
  #  colnames are unique identifiers for samples
  # expt.design: a named list of character vectors, each vector having one element per sample in raw.mat column order, each string representing a design factor OR covariate in the conduct of the experiment
  #   examples: Treatment, Gender, Date, Contaminant_marker_gene_abundance, Sample_purity
  # lm_expression: a string comprising an expression of the form "y  ~ model"
  # response_var gives the string to be used as the name of the response matrix
  #   by default, y is used to represent the multiresponse data matrix
  #   the predictors in the model MUST be named elements of expt.design
  #   example: "y ~ Treatment + Gender"
  # contr_list: a named list, with one element per expt.design element name used in lm_expression, whose contents are either a valid contrasts matrix or a list with elements "baseline" and "contr.FUN"
  #   if contrasts is NULL, default coding will be used
  #      R's default: dummy or treatment contrast, comparing each level to base
  #        by default, alphanumerically first factor level is base
  #        regression coefficients are adjusted group mean ratios to base
  #      useful alternative: summed contrast, comparing levels to grand mean
  #        by default, alphanumerically last factor level is omitted
  #        regression coefficients are adjusted group mean ratios to grand mean
  #   example matrix: dummy or treatment contrast with non-default baseline
  #                   this matrix causes Tx abundances to be compared to Sham
  #                     14d TxA  14d TxB
  #      14d Sham          0        0
  #      14d TxA           1        0
  #      14d TxB           0        1
  #   example list: this list will cause creation of the matrix above
  #   list(baseline="Sham", contr.FUN="contr.treatment") #Other options for contr.FUN = {"contr.helmert", "contr.poly", "contr.sum"} 
  #
  #  NOTE: The following additions are meant to be invisible to prior code!
  #  plot2file: if TRUE - create p-val histogram and q-matrix plots
  #  plotdata is a list of info relevant to labeling and saving the plot
  #     plotdir:  plot destination directory
  #     plotbase:  base filename for the plot. Suggest: bias reduction method
  #     plottitle:  title for all plots
  #     plotoffset:  optional offset for organizing plots  #Feedback what would be an example value of this?
  # #Feedback what about histbins?

  # imports
  require(qvalue)

  # constants
  contr_list_names = c("baseline","contr.FUN"); fundx=2; basedx=1

  # calculate contrasts matrices if contrasts input is provided
  if( !is.null(contr_list) ){
    contr_lsmat = vector(mode='list',length=length(contr_list))
    for( fac in names(contr_list) ){
      # test input assumptions
      if( !any(grepl(fac, names(expt.design))) ){
        stop(paste("Factor",fac,"in contrasts list is not in exptl design list"))
      }
      if( !typeof(expt.design[[fac]]) %in% c("character","double","integer") | 
        !is.null(attr(expt.design[[fac]],"dim")) ){
        stop(paste("Factor",fac,"is not a string or numeric vector"))
      }
      # use tested input
      if(is.list(contr_list[[fac]]) ){
        if(sum(names(contr_list[[fac]]) %in% contr_list_names)<length(contr_list_names) ){
          stop("Missing",paste(contr_list_names,collapse=" or "),"for",fac)
        }
        # create matrix for list input
        myfun = contr_list[[fac]][[contr_list_names[fundx]]]
        mybase = contr_list[[fac]][[contr_list_names[basedx]]]
        if(myfun=="contr.treatment"){
          contr_lsmat[[fac]] = contr.treatment( levels(as.factor(expt.design[[fac]])), base = which(levels(as.factor(expt.design[[fac]])) == mybase) )
        } else if(myfun=="contr.sum"){
          fac_v = c( setdiff(levels(as.factor(expt.design[[fac]])), mybase), mybase) # put baseline last for contr.sum
          contr_lsmat[[fac]] = contr.sum(fac_v)
          colnames(contr_lsmat[[fac]]) = fac_v[1:(length(fac_v)-1)]
        } else {
          stop(paste("Contrast function",myfun,"is not yet supported"))
        }
        # recover matrix input
      } else if(is.matrix(contr_list[[fac]]) ){
        contr_lsmat[fac] = contr_list[fac]
      } else if(class(contr_list[[fac]])=="AsIs" & length(dim(contr_list[[fac]]))==2 ){ # matrix wrapped in I()
        class(contr_lsmat[[fac]]) = "matrix"
        contr_lsmat[fac] = contr_list[fac]
      } else {
        stop(paste("Contrasts specification for",fac,",is not a list or matrix"))
      }
    }
  }
  
  # set up regression formula with environment
  # test input
  if( typeof(lm_expression) != "character" | !is.null(attr(lm_expression,"dim")) ){
    stop("Regression formula was not supplied as a string") 
  }
  # check supplied factors for presence in formula
  lm_fac = regmatches(lm_expression,gregexpr('(?<=[`])([^`]+)(?=[`])|([A-Za-z0-9_.]+)',lm_expression,perl=T))[[1]]
  lm_fac = setdiff(lm_fac, response_var)
  n = length(lm_fac) - sum(lm_fac %in% names(expt.design)) 
  if( n != 0 ){
    test_vec = setdiff(lm_fac, names(expt.design))
    stop(n," regression factors not found in exptl design list: ",paste(test_vec,sep=", "))
  }
  # pull out factors supplied in exptl design for use in lm, & assign contrasts
  lm_list = NULL
  for( lm_name in names(expt.design)[names(expt.design) %in% lm_fac] ){
    if( typeof(expt.design[[lm_name]]) == "character" ) {
      lm_list[[lm_name]] = as.factor(expt.design[[lm_name]])
    } else {
      lm_list[[lm_name]] = expt.design[[lm_name]]
    }
  }
  # add contrasts if contrasts input was given
  if( !is.null(contr_list) ){
    for(fac in names(lm_list) ){
      if( any(grepl( fac, names(contr_lsmat) )) ){
        contrasts(lm_list[[fac]]) = contr_lsmat[[fac]]
      }
    }
  }

  # set up environment for regression, with desired factors present
  # use parent of globalenv as parent of regression env to avoid confounding
  lm_env = list2env( lm_list, parent=parent.env(globalenv()) )
  assign(x=response_var, value=t(normmat), envir=lm_env)
  lm_formula = as.formula( lm_expression, env=lm_env)

  # run regression 
  obj_lm = lm( lm_formula)
  b_mat = t(obj_lm$coefficients)
  p_mat = t(lmPval(obj_lm)$pval); class(p_mat) = "matrix"
  # replace NA p-values (bad for qvalue), at risk of spike at 1 (bad for qvalue)
  p_mat[is.na(p_mat)] = 1

  # convert p-values to q-values for evaluation of factor impact on abundances
  q_list = list()
  for( fac in colnames(p_mat) ){
    myflag = TRUE
    obj_qvalue = tryCatch( qvalue(p_mat[,fac]), 
          error=function(e){myflag=FALSE; cat("No qvalues for",fac,"\n")} )
    if( myflag) { 
      q_list[[fac]] = I(obj_qvalue)
    }
  }

  # Create optional regression plots
  if (plot2file) {
    ### plot p value histogram
    plotID = ifelse(is.numeric(plotdata$plotoffset),paste0(plotdata$plotoffset + 8,"p"),"8p") #Feedback changed from isNumer to is.numeric() -MF
    plotDesc = 'p.value_histogram'
    png(filename = sprintf('%s%s_%s_%s.png', plotdata$plotdir, plotID, plotdata$plotbase, plotDesc),
        width=5,height=5.4,units="in",res=300)
    hist(p_mat[,2], nclass=histbins, main=plotdata$plottitle, xlab = "p-value")
    mtext(lm_expression)
    dev.off()

    ### plot q value matrix plots for each factor
    # Note that the first factor is intercept, no need to plot...
    for (fac in colnames(p_mat)[2:ncol(p_mat)]) {
      plotID = ifelse(is.numeric(plotdata$plotoffset),paste0(plotdata$plotoffset + 8,"q"),"8q") #Feedback changed from isNumber to is.numeric -MF
      plotDesc = "p.value_QC.plot.array"
      png(filename = sprintf('%s%s_%s_%s_%s.png', plotdata$plotdir, plotID, plotdata$plotbase,
                             plotDesc, fac), width=5,height=5.4,units="in",res=300)
      plot(q_list[[fac]], rng=c(0,1), cex.axis=0.6)
      dev.off()
    }

  } # End of plot2file optional summary plots

  # return values
  return( list( b_mat=b_mat, p_mat=p_mat, q_list=q_list ) )

}
designRatios <-
function (normmat, attribs, ratioby_ls,
                         q_list=NULL, cut_ls=NULL, verbose=FALSE) {
# This is intended to calculate differential expression after feature selection
# It will create ratios based on experimental design
# It will also calculate selection masks for each set of cuts
# verbose: comment on progress while building selection mask
# normmat: matrix of experimental data in columns (with headers!)
# attribs: list of sample classifications to be tracked in clustering
#   each list element contains a string vector with one label per sample
# ratioby_ls: list of elements of attribs to use for ratio construction
#   element names are names of elements of attribs
#   list element containing character vector of length 1 declares this factor
#     to be the one used for ratio formation and sets the baseline
#     to the given factor level
#   list element containing character vector of all unique values of a factor
#     instructs to split data by this factor before ratioing
#   example: ratioby_ls = list(genotype='WT', gene=unique(annCol$gene))
# q_list: S3 object of qvalue class (a list!) returned by qvalue()
#   OR a list of such objects, OR NULL if no q-value cuts are intended
# cut_ls: list of pre-specified elements used to select features
#   include_ID = vector of identifiers in rownames(normmat) to spare from qcuts
#   qcut: either a number between 0 and 1 used as an upper qvalue limit for MDS,
#     OR a number >1, assumed to be the top n qvalues to use in heatmap
#     note that all qvalues <= nth qvalue will be included
#     (may increase effective n, especially with borderline qcut)
#   qcutF: optional second qcut to use when q_dir is FALSE
#   q_combine = "OR" or "AND" # union or intersection of multiple qvalue tests
#   q_dir: logical of length(q_list)
#     TRUE: select features with q < qcut for i'th qvalue object
#     FALSE: select features with q > qcut
#   rcut_fold = linear scale ratio for min best abs ratio required
#   icut_fold = linear scale intensity for mean fold above min(normmat) required
#   => include elements to execute cuts; omit to skip
  # arguments

  # q-value cuts
  # main qcut
  if( !exists("q_combine", where=cut_ls) ){
    cut_ls$q_combine = "OR"
  }
  if( !exists("qcut", where=cut_ls) ){
    qflag = "no"
  } else if( !is.numeric(cut_ls$qcut) | cut_ls$qcut<=0 | cut_ls$qcut>nrow(normmat) ){
    stop(paste(cut_ls$qcut,"must be a number > 0 and <= nrow(data)"))
  } else if( cut_ls$qcut <1 ) { # assume this is a qvalue cut
    qflag = "qval"
  } else { # assume this is a number of top genes by qvalue on which to cut
    qflag = "qtop"
  }
  # optional qcut to use for qvalues for factors to be avoided
  if( !exists("qcutF", where=cut_ls) ){
    qflagF = "no"
  } else if( !is.numeric(cut_ls$qcutF) | cut_ls$qcutF<=0 | cut_ls$qcutF>nrow(normmat) ){
    stop(paste(cut_ls$qcutF,"must be a number > 0 and <= nrow(data)"))
  } else if( cut_ls$qcutF <1 ) { # assume this is a qvalue cut
    qflagF = "qval"
  } else { # assume this is a number of top genes by qvalue which to avoid
    qflagF = "qtop"
  }

  # calculate ratios based on experimental design

  # parse design in attribs and ratioby_ls
  splitby_ls = NULL; refmk = logical(length(attribs[[1]])); refmk[]= TRUE
  oneclass = names(ratioby_ls) # may be more than one! pick ref elem below
  for( fac in names(ratioby_ls) ){
    if( length(ratioby_ls[[fac]]) < length(unique(attribs[[fac]])) ){
      # this is the level to use as baseline/reference
      refmk = refmk & attribs[[fac]] == ratioby_ls[[fac]]
      oneclass = fac # MDS plot should be colored by this
    } else {
      # this is a factor by which to divide the data before ratioing
      splitby_ls = c(splitby_ls,attribs[fac])
    }
  }

  # create composite split factor if indicated
  splitfac_v = NULL
  if(!is.null(splitby_ls) ){
    splitfac_v = do.call(paste,c(splitby_ls,sep='.'))
    Usplitfac_v = unique(splitfac_v)
  }

  # create list of ratio matrices based on experimental design
  ratio_lsmat = NULL
  if( !is.null(splitby_ls) ){
    ratio_lsmat = vector(mode='list',length=length(Usplitfac_v))
    names(ratio_lsmat) = Usplitfac_v
    for( fac in Usplitfac_v ) {
      ratio_lsmat[[fac]] = normmat
      ratio_lsmat[[fac]] = ratio_lsmat[[fac]] - rowMeans(ratio_lsmat[[fac]][,refmk & splitfac_v==fac],na.rm=T)
      ratio_lsmat[[fac]] = ratio_lsmat[[fac]][,splitfac_v==fac]
    }
  } else {
    ratio_lsmat[[1]] = normmat
    ratio_lsmat[[1]] = ratio_lsmat[[1]] - rowMeans(ratio_lsmat[[1]][,refmk],na.rm=T)
  }
  # combine ratios to make one matrix (each column represented once)
  ratiomat = do.call(cbind,ratio_lsmat) # do.call reqd for cbind on list

  # mask for rows
  rowmask = logical(nrow(ratiomat)); rowmask[] = TRUE
  # optional qvalue mask
  if( !is.null(q_list) ){
    if( any(grepl("OR",cut_ls$q_combine,ignore.case=TRUE)) ){  rowmask[] = FALSE }
    if( any(grepl("qvalues",names(q_list) )) ){ # one qvalue object supplied
      # rearrange for easier looping
      tmp = q_list; q_list=NULL; q_list[[1]] = tmp
      names(q_list)[1] = "q_list"
    }
    for( i in 1:length(q_list) ){
      if( !any(grepl("qvalues",names(q_list[[i]]) )) ){
        stop("No qvalues in q_list element ",i)
      }
      # set main q-value cut for this qvalue object
      if( !exists("qflag") ){
        warning("Warning! q-value object supplied without q-value cut")
      } else {
        if( qflag=="qtop" ){
          # find q-value cut for given top n features
          qcut = quantile(q_list[[i]]$qvalues, probs=cut_ls$qcut/length(q_list[[i]]$qvalues), na.rm=T)
        } else if( qflag=="qval" ){
          qcut = cut_ls$qcut
        }
      }
      if( !exists("qflagF") ){
        if( exists("q_dir", where=cut_ls) ){
          if( any( !cut_ls$q_dir ) ){
            if( exists("qcut") ){
              message("Q-values to be avoided will use main qcut ",qcut)
            } else {
              warning("No q-value cut given for q-values to be avoided")
            }
          }
        }
      } else {
        if( qflagF=="qtop" ){
          # find q-value cut for given top n features
          qcutF = quantile(q_list[[i]]$qvalues, probs=cut_ls$qcutF/length(q_list[[i]]$qvalues), na.rm=T)
        } else if( qflagF=="qval" ){
          qcutF = cut_ls$qcutF
        }
      }
      if( exists("qcut")|exists("qcutF") ){ # skip q-value filter if no cut
        q_include = FALSE
        if( !exists("q_dir", where=cut_ls) ) { q_include =TRUE
        } else if( cut_ls$q_dir[i] ){ q_include=TRUE }
        if( q_include ){
          if( exists("qcut") ){
            # include significant q-values
            if( any(grepl("OR",cut_ls$q_combine,ignore.case=TRUE)) ){
              rowmask = rowmask | q_list[[i]]$qvalues < qcut
              if(verbose){
                cat("Using OR for q-value cuts, selected =",sum(rowmask),"\n")}
            } else {
              rowmask = rowmask & q_list[[i]]$qvalues < qcut
              if(verbose){
                cat("Using AND for q-value cuts, selected=",sum(rowmask),"\n")}
            }
          } else {
            warning("Not including based on qvalues in ",names(q_list)[i]," with no main qcut")
          }
        } else { # avoid the significant qvalues
          # this is set to AND on assumption we will want to remove
          #  nuisance significance, not to include all non-significant nuisances
          if( exists("qcutF") ){
            rowmask = rowmask & q_list[[i]]$qvalues > qcutF
            if(verbose){cat("Avoiding q-values < qcutF, selected =",sum(rowmask),"\n")}
          } else if( exists("qcut") ){
            rowmask = rowmask & q_list[[i]]$qvalues > qcut
            if(verbose){cat("Avoiding q-values < qcut, selected =",sum(rowmask),"\n")}
          } else {
            warning("Not avoiding based on qvalues in ",names(q_list)[i]," with no main qcut")
          }
        }
      }
    } # end q-list for-loop
  }   # end if q-list

  # optional non-qvalue masks
  # include features
  if( exists("include_ID", where=cut_ls) ){
    rowmask = rowmask | rownames(ratiomat) %in% cut_ls$include_ID
  }
  # exclude ratios
  if( exists("rcut_fold", where=cut_ls) ){
    rowmask = rowmask & apply(X=abs(ratiomat), MARGIN=1, FUN=max, na.rm=T) > log2(cut_ls$rcut_fold)
    if(verbose){cat("Requiring min abs ratio\n")}
  }
  # exclude abundances
  if( exists("icut_fold", where=cut_ls) ){
    rowmask = rowmask & apply(X=normmat, MARGIN=1, FUN=mean, na.rm=T) > ( log2(cut_ls$icut_fold) + min(normmat,na.rm=T) )
    if(verbose){cat("Requiring min expression\n")}
  }

  # report selection size
  message(sprintf('selected rows = %s, !selected rows = %s',
                   sum(rowmask), sum(!rowmask)))


  # return processed data
  invisible( list(ratiomat=ratiomat, rowmask=rowmask, oneclass=oneclass) )


}
