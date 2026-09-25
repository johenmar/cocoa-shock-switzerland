#!/usr/bin/env bash
# Re-download the raw data used in this project into data/raw/.
set -euo pipefail
mkdir -p data/raw && cd data/raw
curl -fsSL -o WorldBank_CMO-Historical-Data-Monthly.xlsx \
  "https://thedocs.worldbank.org/en/doc/74e8be41ceb20fa0da750cda2f6b9e4e-0050012026/related/CMO-Historical-Data-Monthly.xlsx"
curl -fsSL -o BFS_LIK25B25_su-d-05.02.66.xlsx "https://dam-api.bfs.admin.ch/hub/api/dam/assets/36838397/master"
curl -fsSL "https://data.snb.ch/api/cube/devkum/data/csv/de?fromDate=2000-01&toDate=2026-12&dimSel=D0(M0),D1(USD1)" |
  awk -F';' 'BEGIN{print "month,chf_per_usd"} /^"[0-9]{4}-[0-9]{2}"/{gsub(/"/,""); print $1","$4}' > SNB_devkum_USD_CHF_monthly.csv
# BAZG foreign-trade indices by CPA (about 110 MB each): keep only the rows used here
BAZG="https://ocean.bazg.admin.ch/open-data-reports"
curl -fsSL "$BAZG/IX_CPA_EXP_de_v1/IX_CPA_EXP_de_v1.csv" | awk -F';' 'NR==1 || $5 ~ /^108/' > BAZG_IX_CPA_EXP_108x.csv
curl -fsSL "$BAZG/IX_CPA_IMP_de_v1/IX_CPA_IMP_de_v1.csv" | awk -F';' 'NR==1 || $5=="0" || $5 ~ /^(0127|1082)/' > BAZG_IX_CPA_IMP_0127_1082_total.csv
echo "done; sources are updated monthly, so results can differ slightly from the archived files"
