#!/usr/bin/env Rscript
args <- commandArgs(T)
library(parallel)
options(mc.cores = detectCores())
library(data.table)

dt <- fread(args[1])
setnames(dt, c('q', 'qpos', 't', 'tlen', 'ts', 'te', 'type', 'msa', 'exon', 'specific', 'left', 'right', 'start', 'end'))
dt[, specific := as.double(specific)]

# for HLA alleles with frame shift variants, we require reads span over the frame shift site
frame.shift <- fread('data/hla.shift')
setnames(frame.shift, c('t', 'exon', 'shift'))
frame.shift[, type := sub('-E.+', '', t)]
frame.shift[, t := NULL]
setkey(frame.shift, type, exon)
frame.shift <- unique(frame.shift)
setkey(dt, type, exon)
dt <- frame.shift[dt]
spanned <- dt[ts < shift-1 & te > shift+1]

dt <- dt[type %in% spanned$type | !(type %in% frame.shift$type)]

# only keep Class I (A, B, C) and DRB1, DQB1, and DPB1.
ignore <- dt[! msa %in% c('ClassI', 'DRB1', 'DQB1', 'DPB1'), q]
dt <- dt[msa %in% c('ClassI', 'DRB1', 'DQB1', 'DPB1')]
dt[q %in% ignore, specific := 0.1]
dt[specific == 0, specific := 0.1]

# filter pair end matches
dt[, qp := sub('/\\d$', '', q)]
nr <- dt[, .(pair1 = length(unique(q))), keyby = qp]
setkey(dt, qp)
dt <- nr[dt]
nr <- dt[, .(pair2 = length(unique(q))), keyby = .(qp, type)]
setkey(dt, qp, type)
dt <- nr[dt]
dt <- dt[pair1 == pair2]

# filter non-specific matching
#dt <- dt[specific==1 & left==0 & right==0]
dt <- dt[left==0 & right==0]
# TODO, filter core exons

#library(IRanges)
#setkey(dt, t)
#cov <- dt[, .(
#	n = .N, 
#	cov = sum(width(reduce(IRanges(pos, width = len)))),
#), keyby = t]

mat <- dcast(dt, q ~ type, value.var = 'specific', fun.aggregate = max, fill = 0)
qs <- mat$q
mat[, q := NULL]
mat <- as.matrix(mat)
weight <- apply(mat, 1, max)
mat2 <- mat
mat[mat > 0] <- 1

# filter out types with too few reads
counts <- colSums(mat)
summary(counts)
cand <- counts > quantile(counts, 0.25) 
mat <- mat[, cand]
## filter out reads with no alleles mapped to
counts <- rowSums(mat)
summary(counts)
cand <- counts > 0
mat <- mat[cand, ]
qs <- qs[cand]
weight <- weight[cand]

allele.names <- colnames(mat)
allele.genes <- unique(sub('\\*.+', '', allele.names))
n.genes <- length(allele.genes)
alleles <- 1:ncol(mat)
reads <- 1:nrow(mat)
na <- length(alleles)
nr <- length(reads)
gamma <- 0.01
beta <- 0.009

library(lpSolve)
#f.obj <-  c(rep(-gamma, na), rep(1,  nr), rep(-beta, nr), 0  )
f.obj <-  c(rep(-gamma, na), weight,      -beta * weight, 0  )
f.type <- c(rep('b', na),    rep('b',nr), rep('i',   nr), 'i')

all.zero <- c(rep(0, na), rep(0, 2 * nr), 0)
heter <- length(all.zero)

# constraints for 1 or 2 alleles per gene
#f.con.bound <- do.call(rbind, mclapply(allele.genes, function(gene){
#    con <- all.zero
#    con[grep(sprintf("^%s", gene), allele.names)] <- 1
#    rbind(con, con)
#}))
#f.dir.bound <- rep(c('>=', '<='), n.genes)
#f.rhs.bound <- rep(c( 1,    2  ), n.genes)
f.con.bound <- t(matrix(all.zero, nrow = heter, ncol = n.genes))
for(g in seq_along(allele.genes)){
	this.gene <- grep(sprintf("^%s", allele.genes[g]), allele.names)
	f.con.bound[g, this.gene] <- 1
}
f.dir.bound <- rep(c('>=', '<='), each = n.genes)
f.rhs.bound <- rep(c( 1,    2  ), each = n.genes)

zero.m <- t(matrix(all.zero, nrow = heter, ncol = nr))
yindex <- matrix(c(1:nr, na + 1:nr), ncol = 2)
gindex <- matrix(c(1:nr, na + nr + 1:nr), ncol = 2)
# constraints for hit incidence matrix
#system.time(
#f.con.hit <- do.call(rbind, mclapply(1:nr, function(i){
#    con <- all.zero
#    con[1:na] <- mat[i,]
#    con[na + i] <- -1
#    con
#}))
#)
system.time(f.con.hit <- zero.m)
system.time(f.con.hit[yindex] <- -1)
system.time(f.con.hit[, 1:na] <- mat)
f.dir.hit <- rep('>=', nr)
f.rhs.hit <- rep(0, nr)


# num of heterozygous genes
f.con.heter <- all.zero
f.con.heter[1:na] <- 1
f.con.heter[heter] <- -1
f.dir.heter <- '=='
f.rhs.heter <- n.genes

# regularization for heterozygous genes
#system.time(f.con.reg <- do.call(rbind, mclapply(1:nr, function(i){
#    con <- rbind(all.zero, all.zero, all.zero)
#    con[ , na + nr + i] <- 1
#    con[1, na + i] <- -n.genes
#    con[3, na + i] <- -n.genes
#    con[2, heter] <- -1
#    con[3, heter] <- -1
#    con
#})))
#f.dir.reg <- rep(c('<=', '<=', '>='), nr)
#f.rhs.reg <- rep(c(0, 0, -n.genes), nr)

zero.m[gindex] <- 1
f.con.reg1 <- zero.m
f.con.reg2 <- zero.m
f.con.reg3 <- zero.m
f.con.reg2[, heter] <- -1
f.con.reg3[, heter] <- -1
f.con.reg1[yindex] <- -n.genes
f.con.reg3[yindex] <- -n.genes
f.dir.reg <- rep(c('<=', '<=', '>='), each = nr)
f.rhs.reg <- rep(c(0, 0, -n.genes), each = nr)

# final constraints
f.con <- rbind(f.con.hit, f.con.bound, f.con.bound, f.con.heter, f.con.reg1, f.con.reg2, f.con.reg3)
f.dir <- c(f.dir.hit, f.dir.bound, f.dir.heter, f.dir.reg)
f.rhs <- c(f.rhs.hit, f.rhs.bound, f.rhs.heter, f.rhs.reg)

#save.image('temp.rda')

system.time(lps <- lp('max', f.obj, f.con, f.dir, f.rhs, int.vec = which(f.type == 'i'), binary.vec = which(f.type == 'b')))
solution <- lps$solution[alleles]
names(solution) <- allele.names
solution <- solution[order(-solution)]
solution <- solution[solution > 0]
solution <- names(solution)
print(solution)

get.diff <- function(x, y) {
	diff.reads <- qs[which(apply(mat[, c(x, y)], 1, diff) != 0)]
	diff.match <- dt[q %in% diff.reads & type %in% c(solution, x, y)]
	by.others <- diff.match[!type %in% c(x, y)]
	if(x == 'C*06:02'){
		diff.match[, insolution := ifelse(type %in% solution, T, F)]
		diff.match[, good := F]
		diff.match[!q %in% by.others$q, good := T]
	}
	#return(copy(diff.match))
	return(copy(diff.match[!q %in% by.others$q]))
}

max.hit <- sum(apply(mat2[, solution], 1, max))
more <- do.call(rbind, mclapply(solution, function(s){
	minus1 <- solution[solution != s]
	minus1.hit <- apply(mat2[, minus1], 1, max)
	gene <- sub('(.+?)\\*.+', '^\\1', s)
    minus2 <- solution[-grep(gene, solution)]
	minus2.hit <- apply(mat2[, minus2], 1, max)
	others <- allele.names[grepl(gene, allele.names) & !(allele.names %in% solution)]
	other.hit <- sapply(others, function(i) sum(pmax(minus1.hit, mat2[, i])))
	other.hit2 <- sapply(others, function(i) sum(pmax(minus2.hit, mat2[, i])))
	cand <- data.frame('competitor' = others, 'missing' = max.hit - other.hit, 'missing2' = max.hit - other.hit2)
	cand$competitor <- as.character(cand$competitor)
    cand <- cand[order(cand$missing * 1e8 + cand$missing2), ]
#	cand <- rbind(data.frame('competitor' = s, 'missing' = 0), cand)
	cand <- cand[1:30,]
	cand$rank <- 1:nrow(cand)

#	ambig <- subset(cand, rank > 1 & missing == 0)$competitor
	ambig <- subset(cand, missing == 0)$competitor
	sol <- s
	if(length(ambig) > 0){
		bests <- sort(c(s, ambig))
		x <- as.integer(sub('.+?\\*(\\d+):.+', '\\1', bests))
		y <- as.integer(sub('.+?\\*\\d+:(\\d+).*', '\\1', bests))
		bests <- bests[order(x * 1e5 + y)]
		cand <- subset(cand, !competitor %in% ambig)
		ambig <- bests[-1]
		sol <- bests[1]
		bests <- paste(bests, collapse = ';')
		ambig <- paste(ambig, collapse = ';')
		cand$rank <- 1:nrow(cand)
	}else{
		ambig = ''
	}

	competition <- do.call(rbind, lapply(1:nrow(cand), function(i){
		competitor <- cand[i, 'competitor']
		diff.match <- get.diff(s, competitor)
		c(
		  	'rank' = 0,
		  	'solution' = 0,
		  	'missing' = cand[i, 'missing'],
		  	'missing2' = cand[i, 'missing2'],
			'tier1' = 0,
		  	'tier2' = 0,
		  	'tier3' = 0,
			'best.sp' = nrow(diff.match[type == s & specific == 1]),
			'best.nonsp' = nrow(diff.match[type == s & specific <  1]),
			'comp.sp' = nrow(diff.match[type == competitor & specific == 1]),
			'comp.nonsp' = nrow(diff.match[type == competitor & specific <  1])
		)
	}))
	competition <- data.frame(competition)
	competition$solution <- sol
	competition$rank <- 1:nrow(competition)
	competition$competitor <- cand$competitor
	competition$tier1 <- ambig
	competition$tier2 <- paste(subset(competition, best.sp == 0)$competitor, collapse = ';')
	competition$tier3 <- paste(subset(competition, best.sp > 0 & comp.sp > 0 & comp.sp * 5 >= best.sp)$competitor, collapse = ';')

	competition
}))
more <- data.table(more)

important <- function(sol){
	sol <- sub(';.+', '', as.character(sol))
	explained <- sum(apply(mat[, sol], 1, max))
	delta <- explained - sapply(seq_along(sol), function(i) sum(apply(mat[, sol[-i]], 1, max)))
	delta / explained * length(sol)
}
more[, importance := 0]
solution <- unique(sub(';.+', '', more$solution))
more[rank == 1, importance := important(solution)]
more <- more[order(rank)]
print(more[rank == 1])
write.table(more, row = F, col = F, sep = '\t', quo = F, file = args[2])

save.image(file = sprintf('%s.temp.rda', args[2]))