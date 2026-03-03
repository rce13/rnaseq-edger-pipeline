# RNA-seq Analysis Pipeline (edgeR)

RNA-seqデータの一貫解析パイプライン。品質管理からトリミング、アライメント、リードカウント、差次発現解析（edgeR）までを自動で実行します。任意の生物種に対応しています。

An end-to-end RNA-seq analysis pipeline covering quality control, trimming, alignment, read counting, and differential expression analysis with edgeR. Supports any organism with a reference genome.

---

## 目次 / Table of Contents

- [概要 / Overview](#概要--overview)
- [ワークフロー / Workflow](#ワークフロー--workflow)
- [必要環境 / Requirements](#必要環境--requirements)
- [インストール / Installation](#インストール--installation)
- [ディレクトリ構成 / Directory Structure](#ディレクトリ構成--directory-structure)
- [使い方 / Usage](#使い方--usage)
- [出力ファイル / Output Files](#出力ファイル--output-files)
- [リファレンスの準備 / Preparing References](#リファレンスの準備--preparing-references)
- [設定項目 / Configuration](#設定項目--configuration)
- [ライセンス / License](#ライセンス--license)

---

## 概要 / Overview

### 日本語

このパイプラインは、RNA-seqデータの解析を対話的なインターフェースで一貫して実行するBashスクリプトです。

**主な特徴:**
- ペアエンド（PE）/シングルエンド（SE）の自動検出
- `src/` ディレクトリからリファレンスファイル（STARインデックス、GTF）を自動検出
- 対話形式でサンプルのグループ分けと比較ペアを設定
- TPMベースの発現定量とedgeRによる統計検定
- Volcano plot、MA plot、PCA plot等の可視化を自動出力
- **任意の生物種に対応**（リファレンスゲノムとGTFアノテーションを用意するだけ）

### English

This pipeline provides an interactive, end-to-end RNA-seq analysis workflow as a Bash script.

**Key Features:**
- Automatic paired-end (PE) / single-end (SE) detection
- Auto-detection of reference files (STAR index, GTF) from `src/` directory
- Interactive sample grouping and comparison pair setup
- TPM-based expression quantification with edgeR statistical testing
- Automatic generation of Volcano plots, MA plots, PCA plots, and more
- **Works with any organism** — just provide a reference genome and GTF annotation

---

## ワークフロー / Workflow

```
FASTQ files
    │
    ▼
[1] FastQC (Raw)         ── 生データの品質評価
    │
    ▼
[2] Trimmomatic          ── アダプター除去・品質フィルタリング
    │
    ▼
[3] FastQC (Trimmed)     ── トリミング後の品質確認
    │
    ▼
[4] STAR                 ── リファレンスゲノムへのアライメント
    │
    ▼
[5] featureCounts        ── 遺伝子ごとのリードカウント定量
    │
    ▼
[6] MultiQC              ── 統合QCレポート生成
    │
    ▼
[7] edgeR                ── 差次発現解析 (DEG)
    │
    ▼
Results: CSV tables + PDF plots
```

---

## 必要環境 / Requirements

- **OS:** Linux (x86_64) または macOS (Intel / Apple Silicon)
- **ディスク容量:** 5 GB以上（ツールインストール用）+ リファレンスゲノム + FASTQデータ分
- **メモリ:** 16 GB以上推奨（STAR使用時）
- **インターネット接続:** 初回セットアップ時のみ必要

セットアップスクリプトが以下のツールをすべて自動インストールします:

| ツール | 用途 |
|--------|------|
| FastQC | リード品質評価 |
| Trimmomatic | アダプター除去・品質トリミング |
| STAR | RNA-seqアライメント |
| featureCounts (Subread) | リードカウント定量 |
| MultiQC | QCレポート統合 |
| R + edgeR | 差次発現解析 |
| R + ggplot2 | データ可視化 |

---

## インストール / Installation

### 1. リポジトリをクローン / Clone the repository

```bash
git clone https://github.com/rce13/rnaseq-edger-pipeline.git
cd rnaseq-edger-pipeline
```

### 2. 解析環境をセットアップ / Set up the environment

```bash
cd script
chmod +x setup_rnaseq_environment.sh rnaseq_pipeline.sh
./setup_rnaseq_environment.sh
```

このスクリプトは以下を自動的に行います:
- Minicondaをローカルにインストール（`rnaseq_tools/`以下）
- 専用のconda環境を作成
- 全ての必要なバイオインフォマティクスツールとRパッケージをインストール

This script will automatically:
- Install Miniconda locally (under `rnaseq_tools/`)
- Create a dedicated conda environment
- Install all required bioinformatics tools and R packages

---

## ディレクトリ構成 / Directory Structure

使用前に以下の構成を準備してください:

```
rnaseq-edger-pipeline/
├── script/
│   ├── rnaseq_pipeline.sh          # メインパイプライン
│   └── setup_rnaseq_environment.sh # 環境セットアップ
├── src/                             # リファレンスファイル
│   ├── STAR_index_<species>/       # STARゲノムインデックス
│   ├── <species>.gtf               # GTFアノテーション
│   └── <species>.fa                # ゲノムFASTA（任意）
├── fastq/                           # FASTQデータ
│   └── <project_name>/             # プロジェクトごとのディレクトリ
│       ├── Sample1_R1.fastq.gz
│       ├── Sample1_R2.fastq.gz
│       ├── Sample2_R1.fastq.gz
│       └── Sample2_R2.fastq.gz
├── output/                          # 解析結果（自動生成）
├── rnaseq_tools/                    # ツール環境（自動生成）
├── README.md
└── LICENSE
```

---

## 使い方 / Usage

### パイプラインの実行 / Run the pipeline

```bash
cd script
./rnaseq_pipeline.sh
```

対話形式で以下の項目を設定します:

1. **FASTQディレクトリの選択** — `fastq/` 以下から選択
2. **CPUスレッド数** — デフォルト: 8
3. **生物種名** — 記録用（例: "Drosophila", "Human", "Mouse"）
4. **リファレンス選択** — `src/` から自動検出、複数ある場合は選択
5. **サンプルのグループ分け** — 各サンプルを実験群に割り当て
6. **比較ペアの設定** — どのグループ間で差次発現解析を行うか
7. **設定確認** — パラメータを確認して実行開始

### 実行例 / Example session

```
RNA-seq 解析パイプライン

[1] 基本設定

利用可能なFASTQディレクトリ:
  1. my_experiment (8 files)

FASTQディレクトリ: 1
使用するCPUスレッド数 [デフォルト: 8]: 8
生物種 [デフォルト: Drosophila]: Mouse

[2] リファレンスファイルの自動検出
STARインデックスを検出:
  1. STAR_index_GRCm39
  → 自動選択: STAR_index_GRCm39

[3] シーケンスタイプの自動検出
  → 自動検出: ペアエンド (PE) - 4 ペア

[4] サンプル情報の収集
検出されたサンプル: 4件
  1.   Control_rep1
  2.   Control_rep2
  3.   Treatment_rep1
  4.   Treatment_rep2

[5] 実験群の設定
グループ数: 2
グループ1の名前: Control
サンプル番号: 1,2
グループ2の名前: Treatment
サンプル番号: 3,4

[6] 比較ペアの設定
比較: Control-Treatment

この設定で実行しますか？ (yes/no): yes
```

---

## 出力ファイル / Output Files

各実行ごとに `output/output_<project>_<timestamp>/` ディレクトリが作成されます:

```
output_<project>_<timestamp>/
├── 01_fastqc_raw/           # 生データQCレポート
├── 02_trimmed/              # トリミング済みFASTQ
├── 03_fastqc_trimmed/       # トリミング後QCレポート
├── 04_star_aligned/         # BAMアライメントファイル
├── 05_counts/               # リードカウントマトリクス
│   └── gene_counts.txt
├── 06_edgeR/                # 差次発現解析結果
│   ├── TPM_all_samples.csv      # 全サンプルTPM値
│   ├── DEG_TPM_*_all.csv        # 全遺伝子DEG結果
│   ├── DEG_summary.csv          # 結果サマリー
│   ├── Volcano_plot_*.pdf       # ボルケーノプロット
│   ├── PCA_plot_TPM.pdf         # PCAプロット
│   ├── MDS_plot.pdf             # MDSプロット
│   └── BCV_plot.pdf             # BCVプロット
├── 07_multiqc/              # 統合QCレポート
│   └── multiqc_report.html
├── sample_info.txt          # サンプル-グループ対応表
└── pipeline.log             # 実行ログ
```

### DEG結果CSVの列説明 / DEG Result Columns

| 列名 | 説明 |
|------|------|
| gene_name | 遺伝子名（GTFより） |
| gene_id | Ensembl遺伝子ID |
| TPM_* | 各サンプルのTPM値 |
| TPM_mean_* | グループごとのTPM平均値 |
| logFC | log2 Fold Change（TPMベース） |
| PValue | p値 |
| FDR | 偽発見率（BH補正） |

---

## リファレンスの準備 / Preparing References

任意の生物種で使用するには、`src/` ディレクトリに以下を配置します。

To use with any organism, place the following in the `src/` directory.

### 1. ゲノムFASTA と GTF のダウンロード例 / Download example

**Ensemblからのダウンロード例（マウス GRCm39）:**

```bash
cd src

# ゲノムFASTA
wget https://ftp.ensembl.org/pub/release-111/fasta/mus_musculus/dna/Mus_musculus.GRCm39.dna.primary_assembly.fa.gz
gunzip Mus_musculus.GRCm39.dna.primary_assembly.fa.gz

# GTFアノテーション
wget https://ftp.ensembl.org/pub/release-111/gtf/mus_musculus/Mus_musculus.GRCm39.111.gtf.gz
gunzip Mus_musculus.GRCm39.111.gtf.gz
```

**ヒト (GRCh38):**

```bash
wget https://ftp.ensembl.org/pub/release-111/fasta/homo_sapiens/dna/Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz
wget https://ftp.ensembl.org/pub/release-111/gtf/homo_sapiens/Homo_sapiens.GRCh38.111.gtf.gz
```

### 2. STARインデックスの作成 / Build STAR index

```bash
# 環境をアクティベート
source script/activate_env.sh

# STARインデックスを作成
STAR --runMode genomeGenerate \
     --genomeDir src/STAR_index_GRCm39 \
     --genomeFastaFiles src/Mus_musculus.GRCm39.dna.primary_assembly.fa \
     --sjdbGTFfile src/Mus_musculus.GRCm39.111.gtf \
     --runThreadN 8
```

**注意:** STARインデックスの作成にはメモリ約32GB（ヒト/マウスゲノムの場合）と30分〜1時間程度が必要です。

**Note:** Building a STAR index requires ~32 GB RAM (for human/mouse genomes) and takes 30-60 minutes.

---

## 設定項目 / Configuration

### FASTQファイルの命名規則 / FASTQ Naming Convention

| タイプ | パターン |
|--------|----------|
| ペアエンド | `SampleName_R1.fastq.gz` / `SampleName_R2.fastq.gz` |
| ペアエンド（代替） | `SampleName_1.fastq.gz` / `SampleName_2.fastq.gz` |
| シングルエンド | `SampleName.fastq.gz` |

- ファイル名にスペースや特殊文字を使用しないでください
- `.gz` 圧縮が必要です

### Trimmomaticパラメータ / Trimmomatic Parameters

| パラメータ | 値 | 説明 |
|------------|-----|------|
| ILLUMINACLIP | TruSeq3-PE-2.fa:2:30:10 | アダプター配列の除去 |
| LEADING | 3 | 5'端の低品質塩基除去 |
| TRAILING | 3 | 3'端の低品質塩基除去 |
| SLIDINGWINDOW | 4:15 | スライディングウィンドウ品質フィルター |
| MINLEN | 36 | 最小リード長 |

### edgeR解析 / edgeR Analysis

- **レプリケートあり（n≥2）:** `glmQLFTest` による統計検定
- **レプリケートなし（n=1）:** 固定BCV=0.4を使用した `exactTest`（参考値）
- **有意基準:** FDR < 0.05, |log2FC| > 1

---

## ライセンス / License

MIT License - 詳細は [LICENSE](LICENSE) を参照してください。

## 作成者 / Author

rce13 ([@rce13](https://github.com/rce13))
