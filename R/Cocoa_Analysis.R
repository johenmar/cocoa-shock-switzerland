# ------------------------------------------------------------------
# The cocoa price shock 2023-2026 and Swiss chocolate:
# how fast and how far did higher cocoa costs reach Swiss consumer prices and export prices,
# and what happens now that cocoa has fallen again?
#
# Inputs (data/raw/, see README for sources and terms of use)
#   WorldBank_CMO-Historical-Data-Monthly.xlsx   cocoa (ICCO) and sugar prices, USD/kg
#   SNB_devkum_USD_CHF_monthly.csv                CHF per USD, monthly average
#   BFS_LIK25B25_su-d-05.02.66.xlsx               Swiss CPI (LIK), detailed monthly indices
#   BAZG_IX_CPA_EXP_108x.csv / _IMP_...csv        Swiss foreign-trade indices by CPA (value, unit value, volume)
#
# Run from the repository root:  Rscript R/Cocoa_Analysis.R
# ------------------------------------------------------------------
suppressPackageStartupMessages({
  library(data.table); library(readxl); library(sandwich); library(ggplot2); library(scales)
})
dir.create("results", showWarnings = FALSE); dir.create("figures", showWarnings = FALSE)

K <- 24                                  # months of lagged cocoa-price changes in the pass-through models
HAC_LAG <- 12
START <- as.Date("2000-01-01")           # SNB monthly FX series starts here
BACKTEST_END <- as.Date("2023-12-01")    # models for the backtest use data up to this month only
ym <- function(x) as.Date(paste0(x, "-01"))

# ---------------- 1. World Bank cocoa and sugar prices ----------------
wb <- suppressMessages(as.data.table(read_excel("data/raw/WorldBank_CMO-Historical-Data-Monthly.xlsx",
                               sheet = "Monthly Prices", skip = 4, col_names = TRUE)))
setnames(wb, 1, "period")
wb <- wb[grepl("^\\d{4}M\\d{2}$", period),
         .(month = ym(sub("M", "-", period)), cocoa_usd = as.numeric(Cocoa), sugar_usd = as.numeric(`Sugar, world`))]

# ---------------- 2. Exchange rate ----------------
fx <- fread("data/raw/SNB_devkum_USD_CHF_monthly.csv")[, .(month = ym(month), chf_per_usd)]

# ---------------- 3. Swiss CPI (LIK) ----------------
lik_raw <- suppressWarnings(as.data.table(read_excel("data/raw/BFS_LIK25B25_su-d-05.02.66.xlsx", sheet = "INDEX_m", skip = 3)))
datecols <- names(lik_raw)[15:ncol(lik_raw)]
pick <- c("100_1708" = "lik_choc", "100_1001" = "lik_food", "100_100" = "lik_total", "100_1700" = "lik_sugarconf")
lik_sel <- unique(lik_raw[Code %in% names(pick)], by = "Code")   # the total appears twice (main table and special aggregates)
lik_sel[, (datecols) := lapply(.SD, as.numeric), .SDcols = datecols]
lik <- melt(lik_sel[, c("Code", datecols), with = FALSE], id.vars = "Code",
            variable.name = "d", value.name = "v")
lik[, `:=`(month = as.Date(as.numeric(as.character(d)), origin = "1899-12-30"), v = suppressWarnings(as.numeric(v)))]
if (anyNA(lik$month)) lik[, month := as.Date(substr(as.character(d), 1, 10))]
lik <- dcast(lik[, .(month, series = pick[Code], v)], month ~ series, value.var = "v")
lik_weight <- lik_raw[Code == "100_1708", as.numeric(`2026`)]

# ---------------- 4. Swiss foreign-trade indices (BAZG, CPA) ----------------
read_ix <- function(f) {
  d <- fread(f, sep = ";", colClasses = list(character = "Warengruppe_CPA"))
  d[Periode <= 12, .(flow = Verkehrsrichtung, month = as.Date(sprintf("%d-%02d-01", Jahr, Periode)),
                     cpa = Warengruppe_CPA, value_ix = Kettenindex_nominal,
                     uv_ix = Kettenindex_Durchschnittswert, vol_ix = Kettenindex_real, status = Stand)]
}
trade <- rbind(read_ix("data/raw/BAZG_IX_CPA_EXP_108x.csv"), read_ix("data/raw/BAZG_IX_CPA_IMP_0127_1082_total.csv"))
CPA <- c("1082" = "Cocoa, chocolate and sugar confectionery", "10821" = "Cocoa paste, butter and powder",
         "108221" = "Chocolate, in bulk forms", "108222" = "Chocolate, other than in bulk (retail forms)",
         "108223" = "Sugar confectionery without cocoa")
trade <- trade[cpa %in% names(CPA)]
fwrite(trade, "results/trade_indices_selected.csv")

# ---------------- 5. Monthly analysis data ----------------
dat <- Reduce(function(a, b) merge(a, b, by = "month", all = FALSE), list(wb, fx, lik))
dat <- dat[month >= START][order(month)]
dat[, cocoa_chf := cocoa_usd * chf_per_usd]
dat[, `:=`(d_choc = c(NA, diff(log(lik_choc))), d_food = c(NA, diff(log(lik_food))),
           d_cocoa = c(NA, diff(log(cocoa_chf))), d_sugar = c(NA, diff(log(sugar_usd * chf_per_usd))),
           cal = factor(month(month)))]
for (k in 0:K) dat[, (paste0("L", k)) := shift(d_cocoa, k)]
for (k in 0:K) dat[, (paste0("P", k)) := pmax(shift(d_cocoa, k), 0)]
for (k in 0:K) dat[, (paste0("N", k)) := pmin(shift(d_cocoa, k), 0)]
stopifnot(!anyDuplicated(dat$month), all(diff(dat$month) %in% 28:31))
fwrite(dat[, .(month, cocoa_usd, chf_per_usd, cocoa_chf, sugar_usd, lik_choc, lik_food, lik_total)],
       "results/analysis_data_monthly.csv")

# ---------------- Descriptives: the shock ----------------
pk <- dat[which.max(cocoa_chf)]
desc <- data.table(
  item = c("Cocoa, 2022 average (USD/kg)", "Cocoa, peak month (USD/kg)", "Cocoa, August 2026 (USD/kg)",
           "Cocoa, 2022 average (CHF/kg)", "Cocoa, peak month (CHF/kg)", "Cocoa, August 2026 (CHF/kg)",
           "CHF per USD, 2022 average", "CHF per USD, August 2026",
           "LIK chocolate, 2022 average (Dec 2025 = 100)", "LIK chocolate, peak", "LIK chocolate, August 2026",
           "LIK food, 2022 average", "LIK food, August 2026", "Chocolate weight in the LIK basket (%)"),
  value = c(dat[year(month) == 2022, mean(cocoa_usd)], max(dat$cocoa_usd), dat[month == max(month), cocoa_usd],
            dat[year(month) == 2022, mean(cocoa_chf)], pk$cocoa_chf, dat[month == max(month), cocoa_chf],
            dat[year(month) == 2022, mean(chf_per_usd)], dat[month == max(month), chf_per_usd],
            dat[year(month) == 2022, mean(lik_choc)], max(dat$lik_choc), dat[month == max(month), lik_choc],
            dat[year(month) == 2022, mean(lik_food)], dat[month == max(month), lik_food], lik_weight),
  month = c(NA, format(dat[which.max(cocoa_usd)]$month), "2026-08", NA, format(pk$month), "2026-08", NA, "2026-08",
            NA, format(dat[which.max(lik_choc)]$month), "2026-08", NA, "2026-08", "2026"))
fwrite(desc, "results/descriptives.csv")

# ---------------- Q1. Pass-through of cocoa costs to Swiss consumer prices ----------------
# d ln(LIK chocolate)_t = a + sum_k b_k d ln(cocoa, CHF)_{t-k} + c d ln(LIK food)_t + month effects
# The cumulative sum of b_k is the elasticity of consumer chocolate prices to cocoa after k months.
Lk <- paste0("L", 0:K)
f_pt <- as.formula(paste("d_choc ~", paste(Lk, collapse = " + "), "+ d_food + cal"))
est <- dat[!is.na(get(paste0("L", K))) & !is.na(d_choc)]
fit <- lm(f_pt, data = est)
V <- NeweyWest(fit, lag = HAC_LAG, prewhite = FALSE, adjust = TRUE)
cum <- rbindlist(lapply(0:K, function(h) {
  w <- setNames(rep(0, length(coef(fit))), names(coef(fit))); w[paste0("L", 0:h)] <- 1
  e <- sum(w * coef(fit)); s <- sqrt(drop(t(w) %*% V %*% w))
  data.table(horizon = h, elasticity = e, lo = e - 1.96 * s, hi = e + 1.96 * s)
}))
fwrite(cum, "results/q1_passthrough_cumulative.csv")
w_all <- setNames(rep(0, length(coef(fit))), names(coef(fit))); w_all[Lk] <- 1
se_ols <- sqrt(drop(t(w_all) %*% vcov(fit) %*% w_all))
q1_summary <- data.table(ols_lo = cum[horizon == K, elasticity] - 1.96 * se_ols, ols_hi = cum[horizon == K, elasticity] + 1.96 * se_ols,
                         resid_acf1 = cor(resid(fit)[-1], resid(fit)[-nobs(fit)]),
                         n_months = nobs(fit), from = min(est$month), to = max(est$month),
                         lr_elasticity = cum[horizon == K, elasticity], lo = cum[horizon == K, lo], hi = cum[horizon == K, hi],
                         at_6m = cum[horizon == 6, elasticity], at_12m = cum[horizon == 12, elasticity],
                         half_reached_month = cum[elasticity >= 0.5 * cum[horizon == K, elasticity]][1, horizon],
                         food_coef = coef(fit)["d_food"], r2 = summary(fit)$r.squared)
fwrite(q1_summary, "results/q1_passthrough_summary.csv")

# sensitivity analyses of the 24-month elasticity
lr_of <- function(fit, terms, V = NeweyWest(fit, lag = HAC_LAG, prewhite = FALSE, adjust = TRUE)) {
  w <- setNames(rep(0, length(coef(fit))), names(coef(fit))); w[terms] <- 1
  e <- sum(w * coef(fit)); s <- sqrt(drop(t(w) %*% V %*% w)); c(e, e - 1.96 * s, e + 1.96 * s)
}
sens_rows <- list(
  "Main model (24 lags, 2002-2026)" = lr_of(fit, Lk),
  "Without food-price control" = { f <- lm(update(f_pt, . ~ . - d_food), data = est); lr_of(f, Lk) },
  "With sugar-price changes (24 lags)" = {
    for (k in 0:K) est[, (paste0("S", k)) := shift(dat$d_sugar, k)[match(est$month, dat$month)]]
    f <- lm(update(f_pt, as.formula(paste(". ~ . +", paste0("S", 0:K, collapse = " + ")))), data = est); lr_of(f, Lk) },
  "18 lags" = { f <- lm(as.formula(paste("d_choc ~", paste(paste0("L", 0:18), collapse = "+"), "+ d_food + cal")), data = est); lr_of(f, paste0("L", 0:18)) },
  "30 lags" = { d2 <- copy(dat); for (k in 25:30) d2[, (paste0("L", k)) := shift(d_cocoa, k)]
                f <- lm(as.formula(paste("d_choc ~", paste(paste0("L", 0:30), collapse = "+"), "+ d_food + cal")),
                        data = d2[!is.na(L30) & !is.na(d_choc)]); lr_of(f, paste0("L", 0:30)) },
  "Cocoa in USD (no exchange-rate conversion)" = {
    d2 <- copy(dat); d2[, du := c(NA, diff(log(cocoa_usd)))]; for (k in 0:K) d2[, (paste0("L", k)) := shift(du, k)]
    f <- lm(f_pt, data = d2[!is.na(L24) & !is.na(d_choc)]); lr_of(f, Lk) },
  "Up to 2022 only (before the shock)" = { f <- lm(f_pt, data = est[month <= as.Date("2022-12-01")]); lr_of(f, Lk) }
)
q1_sens <- data.table(analysis = names(sens_rows), elasticity = sapply(sens_rows, `[`, 1),
                      lo = sapply(sens_rows, `[`, 2), hi = sapply(sens_rows, `[`, 3))
fwrite(q1_sens, "results/q1_passthrough_sensitivity.csv")

# Alternative specification: absolute pass-through. If makers pass on cocoa costs franc for franc,
# the shelf-price change depends on the CHF change of cocoa relative to the shelf price, so the
# percentage response grows when cocoa becomes a larger share of costs.
dat[, a_cocoa := c(NA, diff(cocoa_chf)) / shift(lik_choc)]
for (k in 0:K) dat[, (paste0("A", k)) := shift(a_cocoa, k)]
Ak <- paste0("A", 0:K)
est[, (Ak) := dat[match(est$month, dat$month), Ak, with = FALSE]]
f_abs <- as.formula(paste("d_choc ~", paste(Ak, collapse = " + "), "+ d_food + cal"))
fit_abs <- lm(f_abs, data = est)

# asymmetry: do increases and decreases pass through equally ("rockets and feathers")?
Pk <- paste0("P", 0:K); Nk <- paste0("N", 0:K)
fit_as <- lm(as.formula(paste("d_choc ~", paste(c(Pk, Nk), collapse = " + "), "+ d_food + cal")), data = est)
Va <- NeweyWest(fit_as, lag = HAC_LAG, prewhite = FALSE, adjust = TRUE)
wv <- function(pos, neg) { w <- setNames(rep(0, length(coef(fit_as))), names(coef(fit_as))); w[pos] <- 1; w[neg] <- -1; w }
asym <- rbindlist(lapply(list(increases = wv(Pk, NULL), decreases = wv(Nk, NULL), difference = wv(Pk, Nk)), function(w) {
  e <- sum(w * coef(fit_as)); s <- sqrt(drop(t(w) %*% Va %*% w)); data.table(elasticity = e, lo = e - 1.96 * s, hi = e + 1.96 * s, p = 2 * pnorm(-abs(e / s)))
}), idcol = "component")
asym[, n_decrease_months_large := est[, sum(d_cocoa < -0.05)]]
fwrite(asym, "results/q1_asymmetry.csv")

# ---------------- Q2. Backtest: could the model have predicted 2024-2026? ----------------
fit_bt <- lm(f_pt, data = est[month <= BACKTEST_END])
bt <- dat[month > BACKTEST_END]
bt[, pred_d := predict(fit_bt, newdata = bt)]
start_level <- dat[month == BACKTEST_END, lik_choc]
bt[, `:=`(pred_level = start_level * exp(cumsum(pred_d)), naive_level = start_level)]
# benchmark 2: long-run average monthly change of the chocolate index before 2024 (drift)
drift <- est[month <= BACKTEST_END, mean(d_choc)]
bt[, drift_level := start_level * exp(drift * seq_len(.N))]
# ex-ante variant: cocoa frozen at its December 2023 level (only information available at the time)
bt_ex <- copy(dat)
bt_ex[month > BACKTEST_END, d_cocoa := 0]
for (k in 0:K) bt_ex[, (paste0("L", k)) := shift(d_cocoa, k)]
bt[, pred_exante := start_level * exp(cumsum(predict(fit_bt, newdata = bt_ex[month > BACKTEST_END])))]
# absolute (cost-share) model, fitted to Dec 2023 and fed with actual cocoa prices
fit_abs_bt <- lm(f_abs, data = est[month <= BACKTEST_END])
bt[, pred_abs := start_level * exp(cumsum(predict(fit_abs_bt, newdata = dat[month > BACKTEST_END])))]
bt_err <- bt[, .(exante_rmse = sqrt(mean((log(lik_choc) - log(pred_exante))^2)) * 100,
                 exante_change = (last(pred_exante) / start_level - 1) * 100,
                 abs_rmse = sqrt(mean((log(lik_choc) - log(pred_abs))^2)) * 100,
                 abs_change = (last(pred_abs) / start_level - 1) * 100,
                 model_elasticity_to_dec2023 = sum(coef(fit_bt)[Lk]),
                 model_rmse = sqrt(mean((log(lik_choc) - log(pred_level))^2)) * 100,
                 nochange_rmse = sqrt(mean((log(lik_choc) - log(naive_level))^2)) * 100,
                 drift_rmse = sqrt(mean((log(lik_choc) - log(drift_level))^2)) * 100,
                 actual_change = (last(lik_choc) / start_level - 1) * 100,
                 model_change = (last(pred_level) / start_level - 1) * 100,
                 months = .N)]
fwrite(bt[, .(month, lik_choc, pred_level, pred_exante, pred_abs, naive_level, drift_level)], "results/q2_backtest_path.csv")
fwrite(bt_err, "results/q2_backtest_errors.csv")

# ---------------- Q3. Outlook: cocoa has fallen, what does the model imply? ----------------
# 12-month projection (Sep 2026 - Aug 2027) from the full model. Past cocoa changes are known;
# future cocoa changes follow a scenario (one-off level change in September 2026, then flat).
# Food prices are held at their average monthly change; month effects are averaged out.
last_m <- max(dat$month)
scen <- data.table(scenario = c("Cocoa stays at the August 2026 level", "Cocoa 25% lower", "Cocoa 25% higher"),
                   step = log(c(1, 0.75, 1.25)))
hist_d <- dat[, .(month, d_cocoa)]
proj <- rbindlist(lapply(seq_len(nrow(scen)), function(i) {
  fut <- data.table(month = seq(last_m, by = "month", length.out = 13)[-1], d_cocoa = c(scen$step[i], rep(0, 11)))
  all_d <- rbind(hist_d, fut)
  b <- coef(fit)[Lk]; cal_eff <- mean(c(0, coef(fit)[grep("^cal", names(coef(fit)))]))
  base <- coef(fit)["(Intercept)"] + cal_eff + coef(fit)["d_food"] * est[, mean(d_food)]
  out <- rbindlist(lapply(fut$month, function(m) {
    idx <- which(all_d$month == m); lags <- all_d$d_cocoa[idx - 0:K]
    data.table(month = m, pred_d = base + sum(b * lags))
  }))
  out[, `:=`(scenario = scen$scenario[i], level = dat[month == last_m, lik_choc] * exp(cumsum(pred_d)))]
}))
# parameter uncertainty for the flat scenario: draw coefficients from N(b, V_HAC)
set.seed(2026)
draws <- MASS::mvrnorm(2000, coef(fit), V)
fut0 <- data.table(month = seq(last_m, by = "month", length.out = 13)[-1], d_cocoa = 0)
all0 <- rbind(hist_d, fut0)
lagmat <- t(sapply(fut0$month, function(m) { idx <- which(all0$month == m); all0$d_cocoa[idx - 0:K] }))
calcols <- grep("^cal", names(coef(fit)), value = TRUE)
sim <- apply(draws, 1, function(b) {
  base <- b["(Intercept)"] + mean(c(0, b[calcols])) + b["d_food"] * est[, mean(d_food)]
  (exp(sum(base + lagmat %*% b[Lk])) - 1) * 100
})
proj_band <- data.table(scenario = "Cocoa stays at the August 2026 level", median = median(sim),
                        lo = quantile(sim, 0.025), hi = quantile(sim, 0.975),
                        cocoa_part = (exp(sum(lagmat %*% coef(fit)[Lk])) - 1) * 100)
fwrite(proj_band, "results/q3_projection_uncertainty.csv")
# the same projection with the absolute (cost-share) model, which fitted the 2024-26 rise better
Vabs <- NeweyWest(fit_abs, lag = HAC_LAG, prewhite = FALSE, adjust = TRUE)
proj_abs <- rbindlist(lapply(seq_len(nrow(scen)), function(i) {
  lvl <- dat[month == last_m, lik_choc]; cc <- dat[, .(month, cocoa_chf, lik_choc)]
  fut_c <- dat[month == last_m, cocoa_chf] * exp(scen$step[i])
  cal_eff <- mean(c(0, coef(fit_abs)[grep("^cal", names(coef(fit_abs)))]))
  base <- coef(fit_abs)["(Intercept)"] + cal_eff + coef(fit_abs)["d_food"] * est[, mean(d_food)]
  hist_a <- dat[, .(month, a = a_cocoa)]
  out <- list(); prev_level <- lvl; a_fut <- c()
  for (j in 1:12) {
    m <- seq(last_m, by = "month", length.out = 13)[j + 1]
    a_now <- if (j == 1) (fut_c - dat[month == last_m, cocoa_chf]) / prev_level else 0
    a_fut <- c(a_fut, a_now)
    lags <- c(rev(a_fut), rev(hist_a$a))[1:(K + 1)]
    d <- base + sum(coef(fit_abs)[Ak] * lags)
    prev_level <- prev_level * exp(d)
    out[[j]] <- data.table(month = m, level = prev_level)
  }
  rbindlist(out)[, scenario := scen$scenario[i]]
}))
proj_abs_summary <- proj_abs[, .(change_12m_pct = (last(level) / dat[month == last_m, lik_choc] - 1) * 100), by = scenario]
fwrite(proj_abs_summary, "results/q3_projection_summary_absolute_model.csv")
fwrite(data.table(model = c("percentage (log) model", "absolute (cost-share) model"),
                  sum_of_lags = c(sum(coef(fit)[Lk]), sum(coef(fit_abs)[Ak])),
                  lo = c(cum[horizon == K, lo], lr_of(fit_abs, Ak)[2]), hi = c(cum[horizon == K, hi], lr_of(fit_abs, Ak)[3]),
                  shelf_pct_per_chf_kg_at_index_100 = c(NA, sum(coef(fit_abs)[Ak]))), "results/q1_model_comparison.csv")
# contribution of cocoa alone (without the intercept/food trend), for interpretation
proj_summary <- proj[, .(change_12m_pct = (last(level) / dat[month == last_m, lik_choc] - 1) * 100), by = scenario]
fwrite(proj, "results/q3_projection_path.csv")
fwrite(proj_summary, "results/q3_projection_summary.csv")

# how much of the cocoa rise and fall is still "in the pipeline"?
pipeline <- data.table(
  cocoa_chf_change_2022_to_peak_pct = (pk$cocoa_chf / dat[year(month) == 2022, mean(cocoa_chf)] - 1) * 100,
  cocoa_chf_change_2022_to_aug2026_pct = (dat[month == last_m, cocoa_chf] / dat[year(month) == 2022, mean(cocoa_chf)] - 1) * 100,
  lik_choc_change_2022_to_aug2026_pct = (dat[month == last_m, lik_choc] / dat[year(month) == 2022, mean(lik_choc)] - 1) * 100,
  lik_food_change_2022_to_aug2026_pct = (dat[month == last_m, lik_food] / dat[year(month) == 2022, mean(lik_food)] - 1) * 100,
  implied_lr_change_pct = (exp(cum[horizon == K, elasticity] * log(dat[month == last_m, cocoa_chf] / dat[year(month) == 2022, mean(cocoa_chf)])) - 1) * 100)
fwrite(pipeline, "results/q3_pipeline.csv")

# ---------------- Q4. Exports: prices up, volumes down? ----------------
ex <- trade[flow == "E" & cpa %in% c("108222", "108221", "10821")]
setorder(ex, cpa, month)
ex[, `:=`(uv12 = frollmean(uv_ix, 12), vol12 = frollmean(vol_ix, 12), val12 = frollmean(value_ix, 12)), by = cpa]
im <- trade[flow == "I" & cpa == "10821"][order(month)][, uv12 := frollmean(uv_ix, 12)]
exp_summary <- ex[, .(uv_2022 = mean(uv_ix[year(month) == 2022]), uv_last12 = last(uv12),
                      vol_2022 = mean(vol_ix[year(month) == 2022]), vol_last12 = last(vol12),
                      val_2022 = mean(value_ix[year(month) == 2022]), val_last12 = last(val12),
                      last_month = max(month)), by = cpa]
exp_summary[, `:=`(uv_change_pct = (uv_last12 / uv_2022 - 1) * 100, vol_change_pct = (vol_last12 / vol_2022 - 1) * 100,
                   val_change_pct = (val_last12 / val_2022 - 1) * 100, label = CPA[cpa])]
imp_summary <- im[, .(cpa, label = CPA[cpa], uv_2022 = mean(uv_ix[year(month) == 2022]), uv_last12 = last(uv12),
                      uv_peak12 = max(uv12, na.rm = TRUE), peak_month = month[which.max(uv12)])][1]
imp_summary[, `:=`(uv_change_pct = (uv_last12 / uv_2022 - 1) * 100, uv_peak_change_pct = (uv_peak12 / uv_2022 - 1) * 100)]
base_sens <- ex[, .(vol_vs_2019 = (last(vol12) / mean(vol_ix[year(month) == 2019]) - 1) * 100,
                     vol_vs_2021 = (last(vol12) / mean(vol_ix[year(month) == 2021]) - 1) * 100,
                     vol_vs_2022 = (last(vol12) / mean(vol_ix[year(month) == 2022]) - 1) * 100,
                     vol_vs_2023 = (last(vol12) / mean(vol_ix[year(month) == 2023]) - 1) * 100,
                     uv_vs_2021 = (last(uv12) / mean(uv_ix[year(month) == 2021]) - 1) * 100,
                     uv_vs_2023 = (last(uv12) / mean(uv_ix[year(month) == 2023]) - 1) * 100), by = cpa]
fwrite(base_sens, "results/q4_exports_base_year_sensitivity.csv")
fwrite(exp_summary, "results/q4_exports_summary.csv")
fwrite(imp_summary, "results/q4_imports_cocoa_semis_summary.csv")

# export-price pass-through (same model, 12-month-smoothed unit values are not used; monthly values)
exu <- merge(dat[, c("month", Lk, "d_food", "cal"), with = FALSE],
             ex[cpa == "108222", .(month, d_uv = c(NA, diff(log(uv_ix))))], by = "month")
fit_ex <- lm(as.formula(paste("d_uv ~", paste(Lk, collapse = " + "), "+ cal")), data = exu[!is.na(L24) & !is.na(d_uv)])
ex_lr <- lr_of(fit_ex, Lk)
fwrite(data.table(series = "Export unit value, chocolate retail forms (CPA 10.82.22)", n = nobs(fit_ex),
                  elasticity = ex_lr[1], lo = ex_lr[2], hi = ex_lr[3]), "results/q4_export_passthrough.csv")

# input manifest and session info
man <- data.table(file = list.files("data/raw", full.names = TRUE))
man[, `:=`(bytes = file.size(file), sha256 = vapply(file, function(f) sub(" .*", "", system2("sha256sum", f, stdout = TRUE)), ""))]
fwrite(man, "results/input_manifest.csv")
writeLines(capture.output(sessionInfo()), "results/session_info.txt")

# ---------------- Figures (16:9 slides) ----------------
BLUE <- "#2a78d6"; ORANGE <- "#eb6834"; GREY <- "#c9c7c1"; GREY_D <- "#6f6d68"
TEXT <- "#1f1f1e"; TEXT2 <- "#52514e"; GRID <- "#e8e7e3"
theme_s <- theme_minimal(base_size = 18) +
  theme(text = element_text(colour = TEXT), axis.text = element_text(colour = TEXT2, size = 15),
        axis.title = element_text(colour = TEXT2, size = 15), panel.grid.minor = element_blank(),
        panel.grid.major.x = element_blank(), panel.grid.major.y = element_line(colour = GRID, linewidth = 0.45),
        legend.position = "top", legend.justification = "left", legend.title = element_blank(),
        legend.text = element_text(size = 15), plot.margin = margin(6, 14, 6, 6))
save <- function(p, name, w = 11, h = 6.6) ggsave(file.path("figures", name), p, width = w, height = h, dpi = 200, bg = "white")
since <- as.Date("2019-01-01")

# F1: cocoa price in USD and CHF
f1 <- melt(dat[month >= since, .(month, `USD per kg` = cocoa_usd, `CHF per kg` = cocoa_chf)], id.vars = "month")
p1 <- ggplot(f1, aes(month, value, colour = variable)) + geom_line(linewidth = 1.1) +
  scale_colour_manual(values = c(`USD per kg` = GREY_D, `CHF per kg` = BLUE)) +
  scale_y_continuous(limits = c(0, NA), expand = expansion(mult = c(0, 0.05))) +
  scale_x_date(date_breaks = "1 year", date_labels = "%Y") + labs(x = NULL, y = "Cocoa price") + theme_s
save(p1, "fig1_cocoa_price.png")

# F2: indexed: cocoa (CHF), LIK chocolate, LIK food, 2022 = 100
b22 <- dat[year(month) == 2022, lapply(.SD, mean), .SDcols = c("cocoa_chf", "lik_choc", "lik_food")]
f2 <- dat[month >= since, .(month, `Cocoa (CHF)` = cocoa_chf / b22$cocoa_chf * 100,
                            `Chocolate, consumer price` = lik_choc / b22$lik_choc * 100,
                            `All food, consumer price` = lik_food / b22$lik_food * 100)]
f2l <- melt(f2, id.vars = "month")
p2a <- ggplot(f2l[variable != "Cocoa (CHF)"], aes(month, value, colour = variable)) +
  geom_hline(yintercept = 100, colour = GREY_D, linewidth = 0.4) + geom_line(linewidth = 1.1) +
  scale_colour_manual(values = c(`Chocolate, consumer price` = BLUE, `All food, consumer price` = GREY_D)) +
  scale_x_date(date_breaks = "1 year", date_labels = "%Y") + labs(x = NULL, y = "Index, 2022 = 100") + theme_s
save(p2a, "fig2_consumer_prices.png")

# F3: cumulative pass-through
pct10 <- function(e) (1.1^e - 1) * 100   # shelf-price change for a 10% higher cocoa price
p3 <- ggplot(cum, aes(horizon, pct10(elasticity))) +
  geom_hline(yintercept = 0, colour = GREY_D, linewidth = 0.4) +
  geom_ribbon(aes(ymin = pct10(lo), ymax = pct10(hi)), fill = "#cfe0f6") +
  geom_line(colour = BLUE, linewidth = 1.2) + geom_point(colour = BLUE, size = 2) +
  scale_x_continuous(breaks = seq(0, K, 6)) +
  labs(x = "Months after a cocoa price change", y = "Chocolate consumer price, %\nper 10% higher cocoa price") + theme_s
save(p3, "fig3_passthrough.png")

# F4: backtest
f4 <- rbind(dat[month >= as.Date("2022-01-01") & month <= BACKTEST_END, .(month, value = lik_choc, series = "Actual")],
            bt[, .(month, value = lik_choc, series = "Actual")],
            bt[, .(month, value = pred_level, series = "Percentage model")],
            bt[, .(month, value = pred_abs, series = "Franc model")],
            bt[, .(month, value = naive_level, series = "No change")])
p4 <- ggplot(f4, aes(month, value, colour = series, linetype = series)) +
  geom_vline(xintercept = BACKTEST_END, colour = GREY, linewidth = 0.6) + geom_line(linewidth = 1.1) +
  scale_colour_manual(values = c(Actual = TEXT, `Percentage model` = "#7fb0ea", `Franc model` = BLUE, `No change` = GREY_D),
                      breaks = c("Actual", "Franc model", "Percentage model", "No change")) +
  scale_linetype_manual(values = c(Actual = "solid", `Percentage model` = "solid", `Franc model` = "solid", `No change` = "22"),
                        breaks = c("Actual", "Franc model", "Percentage model", "No change")) +
  scale_x_date(date_breaks = "1 year", date_labels = "%Y") + labs(x = NULL, y = "Chocolate, consumer price index") + theme_s
save(p4, "fig4_backtest.png")

# F5: exports, chocolate retail forms: unit value and volume (12-month averages), 2022 = 100
e5 <- ex[cpa == "108222" & month >= since]
b5 <- e5[year(month) == 2022, .(uv = mean(uv_ix), vol = mean(vol_ix))]
f5 <- melt(e5[, .(month, `Export price (unit value)` = uv12 / b5$uv * 100, `Export volume` = vol12 / b5$vol * 100)], id.vars = "month")
p5 <- ggplot(f5[!is.na(value)], aes(month, value, colour = variable)) +
  geom_hline(yintercept = 100, colour = GREY_D, linewidth = 0.4) + geom_line(linewidth = 1.2) +
  scale_colour_manual(values = c(`Export price (unit value)` = BLUE, `Export volume` = ORANGE)) +
  scale_x_date(date_breaks = "1 year", date_labels = "%Y") + labs(x = NULL, y = "12-month average, 2022 = 100") + theme_s
save(p5, "fig5_exports.png")

# F6: outlook scenarios
f6 <- rbind(dat[month >= as.Date("2024-01-01"), .(month, level = lik_choc, scenario = "Actual")], proj[, .(month, level, scenario)])
p6 <- ggplot(f6, aes(month, level, colour = scenario)) +
  geom_vline(xintercept = last_m, colour = GREY, linewidth = 0.6) + geom_line(linewidth = 1.1) +
  scale_colour_manual(values = c(Actual = TEXT, `Cocoa stays at the August 2026 level` = BLUE,
                                 `Cocoa 25% lower` = "#7fb0ea", `Cocoa 25% higher` = ORANGE),
                      breaks = c("Actual", "Cocoa 25% higher", "Cocoa stays at the August 2026 level", "Cocoa 25% lower")) +
  guides(colour = guide_legend(nrow = 2)) +
  scale_x_date(date_breaks = "1 year", date_labels = "%Y") + labs(x = NULL, y = "Chocolate, consumer price index") + theme_s
save(p6, "fig6_outlook.png")

cat("\n== descriptives ==\n"); print(desc)
cat("\n== Q1 ==\n"); print(q1_summary); print(q1_sens); print(asym)
cat("\n== Q2 backtest ==\n"); print(bt_err)
cat("\n== abs model ==\n"); print(sum(coef(fit_abs)[Ak])); print(proj_abs_summary); print(fread("results/q1_model_comparison.csv")); print(proj_band); print(base_sens)
cat("\n== Q3 ==\n"); print(proj_summary); print(pipeline)
cat("\n== Q4 ==\n"); print(exp_summary); print(imp_summary); print(ex_lr)
