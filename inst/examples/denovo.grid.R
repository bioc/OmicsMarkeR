
# random test data
set.seed(123)
dat.discr <- create.discr.matrix(
    create.corr.matrix(
        create.random.matrix(nvar = 50, 
                             nsamp = 100, 
                             st.dev = 1, 
                             perturb = 0.2)),
    D = 10
)

df <- data.frame(dat.discr$discr.mat, .classes = dat.discr$classes)

# create tuning grid
denovo.grid(df, "gbm", 3)
