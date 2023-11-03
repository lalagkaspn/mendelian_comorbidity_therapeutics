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
complex_disease_categories = data.table::fread("processed_data/complex_disease_category.txt")
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

### NOTE: 19 Mendelian diseases are causally associated with genes NOT targeted by any existing drug with know drug targets
###       Therefore, we remove them from the downstream analysis
md_comorbidities = md_comorbidities[lapply(md_comorbidities, nrow) > 0] # 71 Mendelian diseases remain

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
  
  # run logistic regression
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
log_reg_results_summary$beta = factor(log_reg_results_summary$beta, levels = c(0, 1), labels = c("No", "Yes"))

ggplot(log_reg_results_summary, aes(x = nr_comorbidities, y = -log10(pvalue))) +
  geom_point(alpha = 0.5, aes(size = nr_drugs, color = beta)) +
  scale_x_discrete(breaks = seq(1, 61, 1)) +
  scale_y_continuous(breaks = seq(0, 11, 1)) +
  labs(title = "Per Mendelian disease analysis",
       subtitle = "LR model: indicated/investigated ~ disease_category + nr_targets + candidate_drug", 
       color = "odds ratio > 1",
       size = "number of drugs") +
  xlab("Number of \ncomplex disease comorbidities") +
  ylab("neg_log10_pvalue") +
  geom_hline(yintercept = -log10(0.05), linetype = "dashed", color = "red") +
  theme_test() +
  # guides(color = guide_legend(override.aes = list(size = 4))) +
  scale_size_continuous(breaks = c(1, 25, 50, 100, 125, 150)) +
  geom_text(data = subset(log_reg_results_summary, beta == 1 & pvalue < 0.05), 
            aes(label = mendelian_disease), 
            nudge_y = 0.16, nudge_x = 0.16) +
  theme(axis.text = element_text(size = 14),
        axis.title = element_text(size = 18),
        title = element_text(size = 18), 
        legend.text = element_text(size = 12))

# histogram drug-to-gene ratio per Mendelian disease
nr_genes_per_md = md_genes %>%
  group_by(mendelian_disease) %>%
  mutate(nr_genes = length(causal_gene)) %>%
  ungroup() %>%
  dplyr::select(mendelian_disease, nr_genes) %>%
  distinct()
log_reg_results_summary = left_join(log_reg_results_summary, nr_genes_per_md, by = "mendelian_disease")
log_reg_results_summary$drug_to_gene_ratio = log_reg_results_summary$nr_drugs / log_reg_results_summary$nr_genes

fig_3a = ggplot(log_reg_results_summary, aes(x = drug_to_gene_ratio)) +
  geom_histogram(color = "black", fill = "lightblue", bins = 71) +
  scale_x_continuous(breaks = seq(0, 95, 5)) +
  xlab("Drug-to-gene ratio") +
  ylab("Number of Mendelian diseases") +
  theme_classic() +
  theme(axis.text = element_text(size = 14),
        axis.title = element_text(size = 18),
        title = element_text(size = 18), 
        legend.text = element_text(size = 12))

fig_3a
ggsave(filename = "Fig3A_drug_to_gene_ratio_per_MD.tiff", 
       path = "figures/",
       width = 10000, height = 4500, device = 'tiff', units = "px",
       dpi = 700, compression = "lzw", type = type_compression)
dev.off()

# number of drugs - rank sum test
log_reg_results_summary$sig = ifelse(log_reg_results_summary$pvalue < 0.05, 1, 0)
log_reg_results_summary$sig = factor(log_reg_results_summary$sig, levels = c(0, 1), labels = c("Non-significant \nMendelian diseases", "Significant \nMendelian diseases"))
fig_3b = ggplot(log_reg_results_summary, aes(y = nr_drugs, x = sig, fill = sig)) +
  geom_violin() +
  geom_jitter(width = 0.1, alpha = 0.5, size = 4) +
  xlab("") +
  ylab("Number of drugs") +
  labs(title = "") +
  scale_y_continuous(breaks = seq(0, 170, 20)) +
  theme_classic() +
  geom_signif(comparisons = list(c("Non-significant \nMendelian diseases", "Significant \nMendelian diseases")),   
              map_signif_level = FALSE, textsize = 7) +
  annotate(geom = "text", x = 1.5, y = 150, label = "WIilcoxon rank-sum test", size = 7) +
  theme(axis.text = element_text(size = 20),
        axis.title = element_text(size = 22),
        legend.position = "none")

fig_3b
ggsave(filename = "Fig3B_rank_sum_test.tiff", 
       path = "figures/",
       width = 7000, height = 8000, device = 'tiff', units = "px",
       dpi = 700, compression = "lzw", type = type_compression)
dev.off()

## -- observed vs permutations -- ##

## Now, that we have the signal that significant Mendelian diseases are targeted by a higher number of drugs compared to non-significant,
## we want to exclude the possibility that our significant results from the main analysis are due to the high number of drugs rather than the comorbidity information

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
## This is equivalent to shuffling the rows of drugs in our logistic regression input

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
log_reg_results_permutation = data.frame(permutation = NA,
                                         odds_ratio = NA,
                                         pvalue = NA)

for (permutation in 1:1000) {
  
  # shuffle the drugs
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
perm_pvalue = sum(pvalue_obs >= log_reg_results_permutation$pvalue) / 1000 # 0.018 = 1.8%
sum(or_obs <= log_reg_results_permutation$odds_ratio) / 1000 # 0.014 = 1.4%

## visualizations of results
fig_3c = ggplot(log_reg_results_permutation, aes(x = -log10(pvalue))) +
  geom_histogram(color = "black", fill = "lightblue") +
  geom_vline(xintercept = -log10(pvalue_obs), color = "red", linewidth = 0.8) +
  xlab("neg_log10_pvalue") +
  ylab("count") +
  scale_x_continuous(breaks = seq(0, 30, 5)) +
  annotate(geom = "text", x = 22.5, y = 95, label = paste0(perm_pvalue * 100, "%"), size = 7, color = "red", fontface = "bold") +
  theme_test() +
  theme(axis.text = element_text(size = 20, family = "Arial", colour = "black"),
        axis.title = element_text(size = 22, family = "Arial", colour = "black"))

fig_3c
ggsave(filename = "Fig3C_permutations.tiff", 
       path = "figures/",
       width = 5000, height = 6000, device = 'tiff', units = "px",
       dpi = 700, compression = "lzw", type = type_compression)
dev.off()
