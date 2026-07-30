# Pipeline Steps

This page gives a brief explanation for the major steps in the pipeline. Last
updated 17/06/24.


## Build-System Tasks

### `process_voter_data`

This task processes the raw data from the l2 files that were extracted by
`00_unzip_l2.R`, and saves them as a series of
[parquet](https://parquet.apache.org/) files, which are much faster to read. It
also standardizes all the columns so that they are consistent between different
files in the collection. Internally, the code uses two schemas that we have
developed,  `yale_schema` and `datavant_schema` these are legacy from another
project, and are mostly kept-around to ensure compatibility with another set of
L2 analysis.

### `clean_physician_data`

This task is responsible for cleaning and consolidating data from the NPPES,
NUCC, and taxonomy files. It reads all of the files and ensures that the
columns are of the right type, before joining all three files together
using the NPI number as a join key. It also subsets the datasets to
physicians labeled as `Allopathic & Osteopathic Physicians`, to ensure we
only have the right kind of provider in our future analyses.


### `locality_sensitive_hash`

This task runs locality sensitive hashing as implemented in the [zoomerjoin
package](https://cran.r-project.org/web/packages/zoomerjoin/index.html) to find
all physician-voter pairs with similar names within each state. This is a
'blocking' step which reduces the number of physician-voter pairs we have to
classify as matches / non-matches by weeding out pairs that are unlikely to
match as the names are dissimilar.

### `add_rf_match_predictions_to_df`

This task takes the LSHed data and the labeled training data as inputs. It uses
the labeled data to train a Random Forest that predicts whether two records are
matches based on several predictors we generate (similarity of the two names,
distance between supposed birth date and graduation from medical
school, etc). It then uses the Random Forest to predict whether each
record in the larger corpus is a match or not a match. The task then returns
the original dataframe with this vector of predictions added as a column named
`match`.

## Stand-Alone Scripts

### `code/00_unzip_l2.R`

!!! Warning inline end

    This script needs access to the Yale network drive that houses the voter
    data; without it the script cannot run and there is no cached alternative.
    The voter file is licensed and cannot be redistributed, so it has to come
    from an approved environment.

This is a standalone script, and is not integrated into the build system. It is
responsible for unzipping the raw l2 files, which are kept on a network drive,
and copying them over to the `data/` folder. If you are running the
code somewhere other than the server, you are responsible for
pointing this code to the correct location of the L2 datasets so
they can be ingested for this pipeline.


### `code/make_training_data.R`

This is a helper script that we used to create the training data used for the
supervised matching algorithms. It takes 1500 random rows from the LSH-ed
dataset, and divides them up into 3 semi-overlapping partitions that were
hand-coded by lab members. The semi-overlapping nature of the partitions allows
us to collect a lot of training data points while also calculating statistics
such as the inter-coder reliability.

### `code/label.R`

This is a 40-line helper script that we used to label some of the training
data. It takes records from the partitioned training data, and asks the user
whether they match or not. The output is then saved into the
`labelled_training_data` directory.

