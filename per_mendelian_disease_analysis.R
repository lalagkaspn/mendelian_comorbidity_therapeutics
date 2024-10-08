### This script implements the per Mendelian disease analysis ###

library(dplyr)
library(data.table)
library(ggplot2)
library(ggsignif)

## Set type for image compression based on operating system
## For macOS, X11 installation is required (link: https://www.xquartz.org/)
# if Windows OS
if (Sys.info()['sysname'] == "Windows") {
  type_compression = "windows"
} 
# if Linux
if (Sys.info()['sysname'] == "Linux") {
  type_compression = "windows"
}
# if macOS
if (Sys.info()['sysname'] == "Darwin") {
  type_compression = "cairo"
} 

## -- load data -- ##

# Mendelian - complex disease comorbidities
md_cd_comorbidities = fread("processed_data/md_cd_comorbidities.txt")
unique_cd = unique(md_cd_comorbidities$complex_disease)
unique_md = unique(md_cd_comorbidities$mendelian_disease)

# complex disease categories
complex_disease_categories = data.table::fread("raw_data/complex_disease_category.txt")
md_cd_comorbidities = left_join(md_cd_comorbidities, complex_disease_categories, by = "complex_disease")

# indicated/investigated drugs for the complex diseases
investigated_indicated_drugs = fread("processed_data/drugs_inv_ind_per_disease.txt")
investigated_indicated_drugs = reshape2::melt(investigated_indicated_drugs, "drugbank_id", colnames(investigated_indicated_drugs)[2:ncol(investigated_indicated_drugs)])
investigated_indicated_drugs = na.omit(investigated_indicated_drugs) ; rownames(investigated_indicated_drugs) = NULL
investigated_indicated_drugs = investigated_indicated_drugs %>%
  dplyr::select(drugbank_id, complex_disease = variable) %>%
  distinct()

# Mendelian disease causal genes
md_genes = data.table::fread("processed_data/md_genes.txt")

# drug - targets
db_drug_targets = fread("processed_data/drugbank_all_drugs_known_targets.txt") %>%
  dplyr::select(db_id, drug_target) %>% 
  distinct()

# number of gene-targets per drug
drugs_nr_targets = fread("processed_data/drugbank_all_drugs_known_targets.txt") %>%
  dplyr::select(db_id, drug_target) %>%
  distinct() %>%
  group_by(db_id) %>% 
  mutate(total_targets = length(drug_target)) %>%
  dplyr::select(db_id, total_targets) %>% 
  ungroup() %>%
  distinct()

## -- find drugs targeting each Mendelian disease genes -- ##

# empty list - each element is a mendelian disease
md_comorbidities = list()
for (md in unique_md) {
  md_comorbidities[[md]] = md_cd_comorbidities %>% filter(mendelian_disease == md) %>% dplyr::select(-comorbidity)
} ; rm(md)

# annotate with Mendelian disease genes
for (i in 1:length(md_comorbidities)) {
  
  # add Mendelian disease genes
  md_comorbidities[[i]] = left_join(md_comorbidities[[i]], md_genes, by = "mendelian_disease")
  md_comorbidities[[i]] = md_comorbidities[[i]] %>% 
    dplyr::select(complex_disease, disease_category, md_gene = causal_gene) %>%
    distinct()
  
  # add drugs targeting the Mendelian disease genes
  md_comorbidities[[i]] = left_join(md_comorbidities[[i]], db_drug_targets, by = c("md_gene" = "drug_target"))
  if (sum(is.na(md_comorbidities[[i]]$db_id)) != 0) {
    md_comorbidities[[i]] = md_comorbidities[[i]][-which(is.na(md_comorbidities[[i]]$db_id)), ] ; rownames(md_comorbidities[[i]]) = NULL
  }
  
  # keep needed columns
  md_comorbidities[[i]] = md_comorbidities[[i]] %>% 
    dplyr::select(complex_disease, disease_category, db_id) %>%
    distinct()
  
  cat(i, "\n")
} ; rm(i)

### NOTE: 22 Mendelian diseases are causally associated with genes NOT targeted by any existing drug with know drug targets
### Therefore, we remove them from the downstream analysis
md_comorbidities = md_comorbidities[lapply(md_comorbidities, nrow) > 0]
length(md_comorbidities) # 68 Mendelian diseases remain

## -- logistic regression per Mendelian disease -- ##

# create list of logistic regression inputs for each Mendelian disease
log_reg_input = vector("list", length = length(md_comorbidities))
names(log_reg_input) = names(md_comorbidities)

for (i in 1:length(md_comorbidities)) {
  
  # if drugs are recommended for repurposing...
  if (nrow(md_comorbidities[[i]]) != 0) {
    
    ## candidate drugs
    candidate_drugs_temp = unique(md_comorbidities[[i]]$db_id)
    
    ## complex diseases that these drugs are recommended for repurposing
    complex_diseases_temp = unique(md_comorbidities[[i]]$complex_disease)
    
    ## complex diseases these drugs are indicated/investigated
    # not all drugs will be indicated/investigated for a disease --> keep this in mind when you build the logistic regression input data frame
    ind_inv_temp = investigated_indicated_drugs %>%
      filter(drugbank_id %in% candidate_drugs_temp) %>%
      mutate(indicated_investigated = 1)
    
    ## create logistic regression input
    
    # each row should be a drug-complex disease pair
    log_reg_input[[i]] = data.frame(drug = rep(candidate_drugs_temp, each = length(unique_cd)))
    
    # add complex diseases
    log_reg_input[[i]]$disease = unique_cd
    
    # add disease category
    log_reg_input[[i]] = left_join(log_reg_input[[i]], complex_disease_categories, by = c("disease" = "complex_disease"))
    
    # add number of targets
    log_reg_input[[i]] = left_join(log_reg_input[[i]], drugs_nr_targets, by = c("drug" = "db_id"))
    
    # add indicated/investigated drugs
    log_reg_input[[i]] = left_join(log_reg_input[[i]], ind_inv_temp, by = c("drug" = "drugbank_id", "disease" = "complex_disease"))
    log_reg_input[[i]]$indicated_investigated = ifelse(is.na(log_reg_input[[i]]$indicated_investigated), 0, 1)
    
    # add drug candidates information
    log_reg_input[[i]]$recommended = ifelse(log_reg_input[[i]]$disease %in% complex_diseases_temp, 1, 0)
  }
  
  ## track progress
  cat(i, "\n")
} ; rm(i, candidate_drugs_temp, complex_diseases_temp, ind_inv_temp)

## run logistic regression
log_reg_results = vector("list", length = length(log_reg_input))
names(log_reg_results) = names(log_reg_input)

for (i in 1:length(log_reg_input)) {
  
  # run logistic regression - with class_weights, as in main analysis due to imbalanced dataset
  glm_fits_temp = glm(indicated_investigated ~  disease_category + total_targets + recommended, 
                      data = log_reg_input[[i]], 
                      family = binomial())
  log_summary_temp = summary(glm_fits_temp)$coefficients
  
  # populate list
  log_reg_results[[i]] = log_summary_temp
  
  ## track progress
  cat(i, "\n")
} ; rm(i, glm_fits_temp, log_summary_temp)

## create a data frame with the results of logistic regression for each Mendelian disease
log_reg_results_summary = data.frame(mendelian_disease = names(md_comorbidities), beta = NA, pvalue = NA)

for (i in 1:length(log_reg_results)){
  
  log_reg_results[[i]] = data.frame(log_reg_results[[i]])
  log_reg_results_summary[i, "beta"] = log_reg_results[[i]]["recommended", "Estimate"]
  log_reg_results_summary[i, "pvalue"] = log_reg_results[[i]]["recommended", "Pr...z.."]
  
} ; rm(i)

log_reg_results_summary = log_reg_results_summary %>% 
  arrange(pvalue)
log_reg_results_summary %>% filter(pvalue < 0.05) %>% nrow() # 9 significant Mendelian diseases at a nominal level (p<0.05)
log_reg_results_summary %>% filter(pvalue < 0.05)

## Permutation test for the significant Mendelian diseases
sig_mds = log_reg_results_summary %>% filter(pvalue < 0.05)
sig_mds = sig_mds[-9, ] # remove that because beta < 0

# create list of logistic regression inputs for each Mendelian disease
log_reg_input_perm = vector("list", length = length(unique(sig_mds$mendelian_disease)))
names(log_reg_input_perm) = unique(sig_mds$mendelian_disease)
md_comorbidities_perm = md_comorbidities[names(log_reg_input_perm)]

log_reg_results_perm = vector("list", length = length(log_reg_input_perm))
names(log_reg_results_perm) = names(log_reg_input_perm)
# populate the list_of_lists with the empty lists
empty_list = vector(mode = "list", length = 1000)
names(empty_list) = paste0("permutation_", 1:1000)
for (i in 1:length(log_reg_results_perm)) {
  log_reg_results_perm[[i]] = empty_list
}

for (perm in 1:1000) {
  for (i in 1:length(md_comorbidities_perm)) {
    
    # if drugs are recommended for repurposing...
    if (nrow(md_comorbidities_perm[[i]]) != 0) {
      
      ## candidate drugs
      candidate_drugs_temp = unique(md_comorbidities_perm[[i]]$db_id)
      ## complex diseases that these drugs are recommended for repurposing - random complex diseases of same number as the actual number of comorbidities for this Mendelian disease
      # in other words, random shuffling of Mendelian disease comorbidities
      complex_diseases_temp = sample(unique_cd, length(unique(md_comorbidities_perm[[i]]$complex_disease)), replace = FALSE)
      ## complex diseases these drugs are indicated/investigated
      # not all drugs will be indicated/investigated for a disease --> keep this in mind when you build the logistic regression input data frame
      ind_inv_temp = investigated_indicated_drugs %>%
        filter(drugbank_id %in% candidate_drugs_temp) %>%
        mutate(indicated_investigated = 1)
      
      ## create logistic regression input
      # each row should be a drug-complex disease pair
      log_reg_input_perm[[i]] = data.frame(drug = rep(candidate_drugs_temp, each = length(unique_cd)))
      # add complex diseases
      log_reg_input_perm[[i]]$disease = unique_cd
      # add disease category
      log_reg_input_perm[[i]] = left_join(log_reg_input_perm[[i]], complex_disease_categories, by = c("disease" = "complex_disease"))
      # add number of targets
      log_reg_input_perm[[i]] = left_join(log_reg_input_perm[[i]], drugs_nr_targets, by = c("drug" = "db_id"))
      # add indicated/investigated drugs
      log_reg_input_perm[[i]] = left_join(log_reg_input_perm[[i]], ind_inv_temp, by = c("drug" = "drugbank_id", "disease" = "complex_disease"))
      log_reg_input_perm[[i]]$indicated_investigated = ifelse(is.na(log_reg_input_perm[[i]]$indicated_investigated), 0, 1)
      # add drug candidates information
      log_reg_input_perm[[i]]$recommended = ifelse(log_reg_input_perm[[i]]$disease %in% complex_diseases_temp, 1, 0)
    }
  } ; rm(i, candidate_drugs_temp, complex_diseases_temp, ind_inv_temp)
  
  ## run logistic regression for each Mendelian disease
  for (z in 1:length(log_reg_input_perm)) {
    # run logistic regression - with class_weights, as in main analysis due to imbalanced dataset
    glm_fits_temp = glm(indicated_investigated ~  disease_category + total_targets + recommended, 
                        data = log_reg_input_perm[[z]], 
                        family = binomial())
    log_summary_temp = summary(glm_fits_temp)$coefficients
    # populate list
    log_reg_results_perm[[z]][[perm]] = log_summary_temp
  } ; rm(z, glm_fits_temp, log_summary_temp)
  
  ## track progress
  cat(perm, "\n")
}

## create a data frame with the results of logistic regression for each Mendelian disease
log_reg_results_perm_summary = data.frame(mendelian_disease = sig_mds$mendelian_disease, perm_pvalue = 1)

for (i in 1:length(log_reg_results_perm)){
  
  perm_or = exp(as.numeric(unlist(lapply(log_reg_results_perm[[i]], function(x) x["recommended", "Estimate"]))))
  perm_pvalue = as.numeric(unlist(lapply(log_reg_results_perm[[i]], function(x) x["recommended", "Pr(>|z|)"])))
  
  ## estimate p-value
  obs_or_temp = exp(log_reg_results[[names(log_reg_results_perm)[[i]]]]["recommended", "Estimate"])
  log_reg_results_perm_summary[i, "perm_pvalue"] = sum(obs_or_temp <= perm_or) / 1000
  
} ; rm(i)

log_reg_results_perm_summary = log_reg_results_perm_summary %>% 
  arrange(perm_pvalue)
log_reg_results_perm_summary %>% filter(perm_pvalue < 0.05) %>% nrow() # 8 / 8 Mendelian diseases are significant after permutations
sig_perm_md = log_reg_results_perm_summary %>% filter(perm_pvalue < 0.05)
log_reg_results_summary$sig_perm = ifelse(log_reg_results_summary$mendelian_disease %in% sig_perm_md$mendelian_disease, "Significant \nMendelian diseases", "Non-significant \nMendelian diseases")

## -- annotate each Mendelian disease with number of complex disease comorbidities and number of drugs targeting its associated genes -- ##

## number of comorbidities per Mendelian disease
md_nr_comorbidities = md_cd_comorbidities %>%
  dplyr::select(mendelian_disease, complex_disease) %>%
  group_by(mendelian_disease) %>%
  mutate(nr_comorbidities = length(complex_disease)) %>%
  ungroup() %>%
  dplyr::select(mendelian_disease, nr_comorbidities) %>%
  distinct()
log_reg_results_summary = left_join(log_reg_results_summary, md_nr_comorbidities, by = "mendelian_disease")

## number of drugs targeting the genes associated with each Mendelian disease
md_genes_drugs = left_join(md_genes, db_drug_targets, by = c("causal_gene" = "drug_target"))
md_genes_drugs = na.omit(md_genes_drugs) ; rownames(md_genes_drugs) = NULL
md_genes_drugs = md_genes_drugs %>%
  group_by(mendelian_disease) %>% 
  mutate(nr_drugs = length(db_id)) %>%
  ungroup() %>%
  dplyr::select(mendelian_disease, nr_drugs) %>% 
  distinct()
log_reg_results_summary = left_join(log_reg_results_summary, md_genes_drugs, by = "mendelian_disease")

## -- visualizations -- ##
log_reg_results_summary = log_reg_results_summary %>% arrange(nr_comorbidities)
log_reg_results_summary$nr_comorbidities = factor(log_reg_results_summary$nr_comorbidities, levels = log_reg_results_summary$nr_comorbidities, labels = log_reg_results_summary$nr_comorbidities)
log_reg_results_summary$beta = ifelse(exp(log_reg_results_summary$beta) > 1, 1, 0)
log_reg_results_summary$beta = factor(log_reg_results_summary$beta, levels = c(0, 1), labels = c("No", "Yes")) # Yes --> OR > 1 | No --> OR < 1

ggplot(log_reg_results_summary, aes(x = nr_drugs, y = -log10(pvalue))) +
  geom_point(alpha = 0.4, size = 1.5, aes(color = beta)) +
  # scale_x_discrete(breaks = seq(1, 61, 1)) +
  scale_y_continuous(breaks = seq(0, 11, 1)) +
  labs(color = "odds ratio > 1") +
  xlab("Number of drugs") +
  ylab("neg_log10_pvalue") +
  geom_hline(yintercept = -log10(0.05), linetype = "dashed", color = "red") +
  theme_classic() +
  theme(axis.text = element_text(size = 14, family = "Arial", color = "black"),
        axis.title = element_text(size = 18, family = "Arial", color = "black"),
        title = element_text(size = 18, family = "Arial", color = "black"),
        legend.text = element_text(size = 12, family = "Arial", color = "black"))

# histogram number of drugs per Mendelian disease
nr_genes_per_md = md_genes %>%
  group_by(mendelian_disease) %>%
  mutate(nr_genes = length(causal_gene)) %>%
  ungroup() %>%
  dplyr::select(mendelian_disease, nr_genes) %>%
  distinct()
log_reg_results_summary = left_join(log_reg_results_summary, nr_genes_per_md, by = "mendelian_disease")
log_reg_results_summary$drug_to_gene_ratio = log_reg_results_summary$nr_drugs / log_reg_results_summary$nr_genes

fig3a = ggplot(log_reg_results_summary, aes(x = nr_drugs)) +
  geom_histogram(color = "black", fill = "lightblue", bins = 71) +
  scale_x_continuous(breaks = c(1, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150)) +
  scale_y_continuous(breaks = seq(0, 11)) +
  xlab("Number of drugs") +
  ylab("Number of Mendelian diseases") +
  theme_classic() +
  theme(axis.text = element_text(size = 28, family = "Arial", color = "black"),
        axis.title = element_text(size = 30, family = "Arial", color = "black"),
        axis.title.x = element_text(margin = margin(t = 15)),
        axis.title.y = element_text(margin = margin(r = 15)))

fig3a
ggsave(filename = "Fig3A_drugs_per_MD.tiff", 
       path = "figures/",
       width = 14, height = 8, device = 'tiff',
       dpi = 700, compression = "lzw", type = type_compression)
dev.off()

# number of drugs - rank sum test
log_reg_results_summary$sig = ifelse(log_reg_results_summary$pvalue < 0.05, 1, 0)
log_reg_results_summary$sig = factor(log_reg_results_summary$sig, levels = c(0, 1), labels = c("Non-significant \nMendelian diseases", "Significant \nMendelian diseases"))
log_reg_results_summary$sig_perm = ifelse(log_reg_results_summary$mendelian_disease %in% sig_perm_md$mendelian_disease, 1, 0)
log_reg_results_summary$sig_perm = factor(log_reg_results_summary$sig_perm, levels = c(0, 1), labels = c("Non-significant \nMendelian diseases", "Significant \nMendelian diseases"))
# nominally significant
ggplot(log_reg_results_summary, aes(y = nr_drugs, x = sig)) +
  geom_boxplot() +
  xlab("") +
  ylab("Number of drugs") +
  labs(title = "") +
  scale_y_continuous(breaks = seq(0, 170, 20)) +
  theme_classic() +
  geom_signif(comparisons = list(c("Significant \nMendelian diseases", "Non-significant \nMendelian diseases")), test = "wilcox.test", test.args = list(alternative = "greater"),
              map_signif_level = FALSE, textsize = 14) +
  annotate(geom = "text", x = 1.5, y = 150, label = "Wilcoxon rank-sum test", size = 12) +
  theme(axis.text.x = element_text(size = 35, family = "Arial", color = "black", margin = margin(t = 15)),
        axis.text.y = element_text(size = 35, family = "Arial", color = "black"),
        axis.title.y = element_text(size = 35, family = "Arial", color = "black", margin = margin(r = 15)),
        legend.position = "none")
fig_3b
ggsave(filename = "Fig3B_per_MD_drugs.tiff", 
       path = "figures/",
       width = 14, height = 13, device = 'tiff',
       dpi = 700, compression = "lzw", type = type_compression)
dev.off()

# significant after permutations
fig_3b = ggplot(log_reg_results_summary, aes(y = nr_drugs, x = sig_perm)) +
  geom_boxplot() +
  xlab("") +
  ylab("Number of drugs") +
  labs(title = "") +
  scale_y_continuous(breaks = seq(0, 170, 20)) +
  theme_classic() +
  geom_signif(comparisons = list(c("Significant \nMendelian diseases", "Non-significant \nMendelian diseases")), test = "wilcox.test", test.args = list(alternative = "greater"),
              map_signif_level = FALSE, textsize = 14) +
  annotate(geom = "text", x = 1.5, y = 150, label = "Wilcoxon rank-sum test", size = 12) +
  theme(axis.text.x = element_text(size = 35, family = "Arial", color = "black", margin = margin(t = 15)),
        axis.text.y = element_text(size = 35, family = "Arial", color = "black"),
        axis.title.y = element_text(size = 35, family = "Arial", color = "black", margin = margin(r = 15)),
        legend.position = "none")
fig_3b
ggsave(filename = "Fig3B_per_MD_drugs.tiff", 
       path = "figures/",
       width = 14, height = 13, device = 'tiff',
       dpi = 700, compression = "lzw", type = type_compression)
dev.off()

#### Excluding the possibility that our results are due to the high number of drugs rather than the information about comorbiditiy ####
# Mendelian - complex disease comorbidities
md_cd_comorbidities = md_cd_comorbidities %>% 
  dplyr::select(mendelian_disease, complex_disease) %>%
  arrange(mendelian_disease)

# drugs targeting md_genes
drugs_targeting_md_genes = left_join(md_genes, db_drug_targets, by = c("causal_gene" = "drug_target")) %>%
  na.omit() %>%
  dplyr::select(db_id) %>%
  distinct()

### -- observed -- ###

## create logistic regression input
# each row is a drug-complex disease pair
log_input_obs = data.frame(db_id = rep(drugs_targeting_md_genes$db_id, each = length(unique_cd)))

# add complex diseases
log_input_obs$complex_disease = unique_cd

# add disease category
log_input_obs = left_join(log_input_obs, complex_disease_categories, by = "complex_disease")

# add candidate drugs information
x = left_join(md_cd_comorbidities, md_genes, by = "mendelian_disease")
x = na.omit(x) ; rownames(x) = NULL
x = x %>% dplyr::select(complex_disease, causal_gene) %>% distinct
x = left_join(x, db_drug_targets, by = c("causal_gene" = "drug_target"))
x = na.omit(x) ; rownames(x) = NULL
x = x %>% dplyr::select(-causal_gene) %>% distinct()
x$recommended = 1
log_input_obs = left_join(log_input_obs, x, by = c("complex_disease", "db_id"))
log_input_obs$recommended = ifelse(is.na(log_input_obs$recommended), 0, 1)

# number of drug targets
log_input_obs = left_join(log_input_obs, drugs_nr_targets, by = c("db_id" = "db_id"))

# add investigated/indicated drugs
investigated_indicated_drugs$indicated_investigated = 1
log_input_obs = left_join(log_input_obs, investigated_indicated_drugs, by = c("db_id" = "drugbank_id", "complex_disease" = "complex_disease"))
log_input_obs$indicated_investigated = ifelse(is.na(log_input_obs$indicated_investigated), 0, 1)

# logistic regression
glm_fit_obs = glm(indicated_investigated ~ total_targets + disease_category + recommended,
                  data = log_input_obs, 
                  family = binomial())
log_reg_summary_obs = summary(glm_fit_obs)$coefficients
or_obs = exp(log_reg_summary_obs[8, 1])
pvalue_obs = log_reg_summary_obs[8, 4]

## -- permutations -- ##

## NOTE: in this permutation analysis, we shuffle the drugs targeting each Mendelian disease.
## This is equivalent to shuffling the order of drugs in our logistic regression input

## create logistic regression input
# each row is a drug-complex disease pair
log_input_perm = data.frame(db_id = rep(drugs_targeting_md_genes$db_id, each = length(unique_cd)))

# add complex diseases
log_input_perm$complex_disease = unique_cd

# add disease category
log_input_perm = left_join(log_input_perm, complex_disease_categories, by = "complex_disease")

# add candidate drugs information
x = left_join(md_cd_comorbidities, md_genes, by = "mendelian_disease")
x = na.omit(x) ; rownames(x) = NULL
x = x %>% dplyr::select(complex_disease, causal_gene) %>% distinct
x = left_join(x, db_drug_targets, by = c("causal_gene" = "drug_target"))
x = na.omit(x) ; rownames(x) = NULL
x = x %>% dplyr::select(-causal_gene) %>% distinct()
x$recommended = 1
log_input_perm = left_join(log_input_perm, x, by = c("complex_disease", "db_id"))
log_input_perm$recommended = ifelse(is.na(log_input_perm$recommended), 0, 1)

## perform permutation analysis 
# empty data frame to populate with permutation results
log_reg_results_permutation = data.frame(permutation = NA, odds_ratio = NA, pvalue = NA)

for (permutation in 1:1000) {
  
  # shuffle the drugs targeting each Mendelian disease
  drugs_original = unique(log_input_perm$db_id)
  drugs_shuffled = sample(drugs_original, replace = FALSE)
  log_input_perm_temp = log_input_perm
  log_input_perm_temp$db_id = rep(drugs_shuffled, each = 65)
  
  # add number of drug targets
  log_input_perm_temp = left_join(log_input_perm_temp, drugs_nr_targets, by = c("db_id" = "db_id"))
  
  # add investigated/indicated drugs
  log_input_perm_temp = left_join(log_input_perm_temp, investigated_indicated_drugs, by = c("db_id" = "drugbank_id", "complex_disease" = "complex_disease"))
  log_input_perm_temp$indicated_investigated = ifelse(is.na(log_input_perm_temp$indicated_investigated), 0, 1)
  
  # run logistic regression
  glm_fit_perm_temp = glm(indicated_investigated ~ total_targets + disease_category + recommended,
                          data = log_input_perm_temp, 
                          family = binomial())
  log_reg_summary_temp = summary(glm_fit_perm_temp)$coefficients
  
  # populate the results data frame
  log_reg_results_permutation[permutation, "permutation"] = permutation
  log_reg_results_permutation[permutation, "odds_ratio"] = exp(log_reg_summary_temp[8, 1])
  log_reg_results_permutation[permutation, "pvalue"] = log_reg_summary_temp[8, 4]
  
  ## track progress
  cat(permutation, "\n")
}

## calculate p-value after permutations
sum(pvalue_obs >= log_reg_results_permutation$pvalue) / 1000
sum(or_obs <= log_reg_results_permutation$odds_ratio) / 1000

## -- gene level analysis -- ##

# histogram of number of drugs per Mendelian gene
md_genes_drugs = left_join(md_genes, db_drug_targets, by = c("causal_gene" = "drug_target"))
md_genes_drugs = md_genes_drugs %>%
  dplyr::select(causal_gene, db_id) %>%
  distinct() %>%
  group_by(causal_gene) %>% 
  mutate(nr_drugs = if_else(sum(is.na(unique(db_id))) == 1, "0", "over_0")) %>%
  mutate(nr_drugs = if_else(nr_drugs != "0", length(unique(db_id)), 0)) %>%
  ungroup() %>%
  dplyr::select(causal_gene, nr_drugs) %>% 
  distinct() %>%
  filter(nr_drugs > 0)

fi3c = ggplot(md_genes_drugs, aes(x = nr_drugs)) +
  geom_histogram(color = "black", fill = "lightblue", bins = 75) +
  scale_x_continuous(breaks = c(1, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85)) +
  scale_y_continuous(breaks = seq(0, 75, 10)) +
  xlab("Number of drugs") +
  ylab("Number of genes") +
  theme_classic() +
  theme(axis.text = element_text(size = 28, family = "Arial", color = "black"),
        axis.title = element_text(size = 30, family = "Arial", color = "black"),
        axis.title.x = element_text(margin = margin(t = 15)),
        axis.title.y = element_text(margin = margin(r = 15)))

fi3c
ggsave(filename = "Fig3C_drugs_per_MD_gene.tiff", 
       path = "figures/",
       width = 14, height = 8, device = 'tiff',
       dpi = 700, compression = "lzw", type = type_compression)
dev.off()

## analysis per Mendelian disease gene
# keep druggable md genes
md_genes_druggable = md_genes %>% filter(causal_gene %in% db_drug_targets$drug_target)
unique_md_genes = unique(md_genes_druggable$causal_gene)
lr_inputs = vector("list", length(unique(unique_md_genes)))
names(lr_inputs) = unique_md_genes

for (i in 1:length(unique_md_genes)) {
  
  # gene
  md_gene_temp = unique_md_genes[[i]]
  
  # drugs targeting that gene
  drugs_targeting_md_gene_temp = db_drug_targets %>% filter(drug_target == md_gene_temp)
  drugs_targeting_md_gene_temp = unique(drugs_targeting_md_gene_temp$db_id)
  
  # Mendelian diseases linked to that gene
  md_disease_temp = md_genes %>% filter(causal_gene == md_gene_temp)
  md_disease_temp = unique(md_disease_temp$mendelian_disease)
  
  # comorbidities of these Mendelian diseases
  md_comorbidities_temp = md_cd_comorbidities %>% filter(mendelian_disease %in% md_disease_temp)
  md_comorbidities_temp = unique(md_comorbidities_temp$complex_disease)
  
  # each row should be a drug-complex disease pair
  log_input = data.frame(drug = rep(drugs_targeting_md_gene_temp, each = length(unique_cd)))
  
  # add complex diseases
  log_input$disease = unique_cd
  
  # add disease category
  log_input = left_join(log_input, complex_disease_categories, by = c("disease" = "complex_disease"))
  
  # add number of targets
  log_input = left_join(log_input, drugs_nr_targets, by = c("drug" = "db_id"))
  
  # add indicated/investigated drugs
  log_input = left_join(log_input, investigated_indicated_drugs, by = c("drug" = "drugbank_id", "disease" = "complex_disease"))
  log_input$indicated_investigated = ifelse(is.na(log_input$indicated_investigated), 0, 1)
  
  # add recommended candidate drugs
  log_input$recommended = ifelse(log_input$disease %in% md_comorbidities_temp, 1, 0)

  lr_inputs[[i]] = log_input
  
  cat(i, "-", length(unique_md_genes), "\n")
}

## run logistic regression
log_reg_results = data.frame(md_genes = unique_md_genes, comorbidity_OR = NA, comorbidity_P = NA)

for (i in 1:nrow(log_reg_results)) {
  
  # run logistic regression
  if (length(unique(lr_inputs[[i]]$total_targets)) == 1) {
    glm_fits_temp = glm(indicated_investigated ~  disease_category + recommended, 
                        data = lr_inputs[[i]], 
                        family = binomial())
    log_summary_temp = as.data.frame(summary(glm_fits_temp)$coefficients)
    log_reg_results[i, "comorbidity_OR"] = exp(log_summary_temp[7, 1])
    log_reg_results[i, "comorbidity_P"] = log_summary_temp[7, 4]
    
  }
  
  if (length(unique(lr_inputs[[i]]$total_targets)) > 1) {
    glm_fits_temp = glm(indicated_investigated ~  disease_category + total_targets + recommended, 
                        data = lr_inputs[[i]], 
                        family = binomial())
    log_summary_temp = as.data.frame(summary(glm_fits_temp)$coefficients)
    log_reg_results[i, "comorbidity_OR"] = exp(log_summary_temp[8, 1])
    log_reg_results[i, "comorbidity_P"] = log_summary_temp[8, 4]
  }
  
  cat(i, "-", nrow(log_reg_results), "\n")
}

log_reg_results$sig = ifelse(log_reg_results$comorbidity_P < 0.05, 1, 0)

## add nr of targets for each MD gene
md_genes_druggable = left_join(md_genes_druggable, db_drug_targets, by = c("causal_gene" = "drug_target"))
md_genes_druggable = md_genes_druggable %>% 
  group_by(causal_gene) %>%
  mutate(nr_drugs = length(unique(db_id))) %>%
  ungroup() %>%
  distinct()
md_genes_nr_drugs = md_genes_druggable %>%
  dplyr::select(causal_gene, nr_drugs) %>% 
  distinct()

log_reg_results = left_join(log_reg_results, md_genes_nr_drugs, by = c("md_genes" = "causal_gene"))
log_reg_results$sig = factor(log_reg_results$sig, levels = c("0", "1"), labels = c("Non-significant \ngenes", "Significant \ngenes"))

## permutations analysis to exclude the possibility that the results are due to the high number of drugs targeting some of the genes
## each time, shuffle the predictor vector of "recommended" drugs based on comorbidity --> it is the same as shuffling the comorbidities of the Mendelian diseases
## linked to a gene
per_md_gene_permutation_results = vector("list", 1000)
names(per_md_gene_permutation_results) = paste0("permutation_", 1:1000)

for (permutation in 1:1000) {
  
  ## shuffle the predictor vector of "recommended"
  lr_inputs_permuted = lr_inputs
  lr_inputs_permuted = lapply(lr_inputs_permuted, function(x) {
    x$recommended = sample(x$recommended, size = nrow(x), replace = FALSE)
    return(x)
  })
  
  ## logistic regression
  log_reg_results_perm = data.table(md_gene = names(lr_inputs_permuted), 
                                    perm_OR = 0,
                                    perm_pvalue = 0)
  
  for (i in 1:nrow(log_reg_results_perm)) {
    
    # run logistic regression
    glm_fits_temp = glm(indicated_investigated ~ disease_category + total_targets + recommended, 
                        data = lr_inputs_permuted[[log_reg_results_perm[i, md_gene]]], 
                        family = binomial())
    log_summary_temp = summary(glm_fits_temp)$coefficients
    log_reg_results_perm[i, "perm_OR"] = exp(log_summary_temp["recommended", "Estimate"])
    log_reg_results_perm[i, "perm_pvalue"] = log_summary_temp["recommended", "Pr(>|z|)"]
  }
  
  # populate list
  per_md_gene_permutation_results[[paste0("permutation_", permutation)]] = log_reg_results_perm
  
  cat(permutation, "\n")
}

# calculate permuted p-values for each gene
per_md_gene_permuted_pvalues = data.table(md_gene = log_reg_results$md_genes, 
                                          perm_pvalue_OR_based = 0,
                                          perm_pvalue_pvalue_based = 0)
for (i in 1:nrow(per_md_gene_permuted_pvalues)) {
  gene_temp = per_md_gene_permuted_pvalues[i, md_gene]
  
  obs_or = log_reg_results[i, "comorbidity_OR"]
  obs_pvalue = log_reg_results[i, "comorbidity_P"]
  
  perm_or = c()
  perm_pvalue = c()
  for (z in 1:length(per_md_gene_permutation_results)) {
    perm_or = c(perm_or, per_md_gene_permutation_results[[z]][i, perm_OR])
    perm_pvalue = c(perm_pvalue, per_md_gene_permutation_results[[z]][i, perm_pvalue])
  }
  
  per_md_gene_permuted_pvalues[i, "perm_pvalue_OR_based"] = sum(obs_or <= perm_or) / 1000
  per_md_gene_permuted_pvalues[i, "perm_pvalue_pvalue_based"] = sum(obs_pvalue >= perm_pvalue) / 1000
  
  cat(i, "\n")
}

per_md_gene_permuted_pvalues$perm_sig = ifelse(per_md_gene_permuted_pvalues$perm_pvalue_OR_based < 0.05, 1, 0)

log_reg_results = left_join(log_reg_results, per_md_gene_permuted_pvalues[, c(1,4)], by = c("md_genes" = "md_gene"))
log_reg_results$perm_sig = ifelse(log_reg_results$sig == "Non-significant \ngenes", 0, log_reg_results$perm_sig) # 12 / 12 MD genes are significant after permutations

log_reg_results$perm_sig = factor(log_reg_results$perm_sig, levels = c("0", "1"), labels = c("Non-significant \ngenes", "Significant \ngenes"))

fig_3d = ggplot(log_reg_results, aes(x = perm_sig, y = nr_drugs)) +
  geom_boxplot() +
  xlab("") +
  ylab("Number of drugs") +
  geom_signif(comparisons = list(c("Significant \ngenes", "Non-significant \ngenes")), test.args = list(alternative = "greater"), 
              map_signif_level = FALSE, textsize = 14) +
  annotate(geom = "text", x = 1.5, y = 85, label = "WIilcoxon rank-sum test", size = 12) +
  scale_y_continuous(breaks = seq(0, 85, 10)) +
  theme_classic() +
  theme(axis.text.x = element_text(size = 35, family = "Arial", color = "black", margin = margin(t = 15)),
        axis.text.y = element_text(size = 35, family = "Arial", color = "black"),
        axis.title.y = element_text(size = 35, family = "Arial", color = "black", margin = margin(r = 15)),
        legend.position = "none")

fig_3d
ggsave(filename = "Fig3D_per_gene_drugs.tiff", 
       path = "figures/",
       width = 14, height = 13, device = 'tiff',
       dpi = 700, compression = "lzw", type = type_compression)
dev.off()
