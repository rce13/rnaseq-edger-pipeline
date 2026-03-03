#!/usr/bin/env bash

################################################################################
# RNA-seq解析パイプライン (シングルエンド/ペアエンド対応)
# Trimmomatic → STAR → featureCounts → edgeR
# FastQC/MultiQCによるQC実施
#
# 作成者: rce13
# 作成日: 2025-12-15
# 更新日: 2025-12-15 (ディレクトリ構造対応、自動認識機能追加)
################################################################################

set -e  # エラー時に停止

################################################################################
# ベースディレクトリの設定
################################################################################

# スクリプトのあるディレクトリを基準にベースディレクトリを自動設定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLS_DIR="${BASE_DIR}/rnaseq_tools"
SRC_DIR="${BASE_DIR}/src"
FASTQ_BASE_DIR="${BASE_DIR}/fastq"
OUTPUT_BASE_DIR="${BASE_DIR}/output"

MINICONDA_DIR="${TOOLS_DIR}/miniconda3"
CONDA_ENV_DIR="${TOOLS_DIR}/conda_env"
ACTIVATE_SCRIPT="${SCRIPT_DIR}/activate_env.sh"

################################################################################
# ツール環境の自動設定
################################################################################

# 環境アクティベーションスクリプトが存在する場合は使用
if [ -f "$ACTIVATE_SCRIPT" ]; then
    echo "RNA-seq解析環境をアクティベート中..."
    source "$ACTIVATE_SCRIPT"
    TRIMMOMATIC_ADAPTER_DIR="${CONDA_ENV_DIR}/share/trimmomatic/adapters"
elif [ -d "$CONDA_ENV_DIR" ] && [ -f "${MINICONDA_DIR}/etc/profile.d/conda.sh" ]; then
    # activate_env.shがない場合は直接アクティベート
    source "${MINICONDA_DIR}/etc/profile.d/conda.sh"
    conda activate "$CONDA_ENV_DIR"
    TRIMMOMATIC_ADAPTER_DIR="${CONDA_ENV_DIR}/share/trimmomatic/adapters"
    echo "ローカルツール環境を使用: ${CONDA_ENV_DIR}"
else
    # ローカル環境がない場合はエラーメッセージを表示
    echo ""
    echo "================================================================"
    echo "エラー: RNA-seq解析環境が見つかりません"
    echo "================================================================"
    echo ""
    echo "まず環境をセットアップしてください:"
    echo "  ./setup_rnaseq_environment.sh"
    echo ""
    exit 1
fi

# 色付き出力用
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}  RNA-seq 解析パイプライン${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""
echo "ベースディレクトリ: ${BASE_DIR}"
echo "リファレンスディレクトリ: ${SRC_DIR}"

################################################################################
# 1. ユーザー入力の収集
################################################################################

echo ""
echo -e "${GREEN}[1] 基本設定${NC}"

# FASTQファイルのディレクトリ選択
echo ""
echo -e "${YELLOW}利用可能なFASTQディレクトリ:${NC}"
FASTQ_DIRS=()
idx=1
for dir in "$FASTQ_BASE_DIR"/*; do
    if [ -d "$dir" ]; then
        DIRNAME=$(basename "$dir")
        FASTQ_DIRS+=("$DIRNAME")
        FILE_COUNT=$(ls -1 "$dir"/*.fastq.gz 2>/dev/null | wc -l)
        echo "  ${idx}. ${DIRNAME} (${FILE_COUNT} files)"
        ((idx++))
    fi
done

echo ""
echo -e "${YELLOW}ヒント: 番号またはディレクトリ名を入力${NC}"
read -p "FASTQディレクトリ: " FASTQ_INPUT

# 番号が入力された場合
if [[ "$FASTQ_INPUT" =~ ^[0-9]+$ ]]; then
    FASTQ_IDX=$((FASTQ_INPUT - 1))
    if [ $FASTQ_IDX -ge 0 ] && [ $FASTQ_IDX -lt ${#FASTQ_DIRS[@]} ]; then
        FASTQ_DIRNAME="${FASTQ_DIRS[$FASTQ_IDX]}"
        FASTQ_DIR="${FASTQ_BASE_DIR}/${FASTQ_DIRNAME}"
    else
        echo -e "${RED}エラー: 無効な番号です${NC}"
        exit 1
    fi
# パスが入力された場合
elif [[ "$FASTQ_INPUT" == /* ]]; then
    FASTQ_DIR="$FASTQ_INPUT"
    FASTQ_DIRNAME=$(basename "$FASTQ_DIR")
else
    FASTQ_DIRNAME="$FASTQ_INPUT"
    FASTQ_DIR="${FASTQ_BASE_DIR}/${FASTQ_DIRNAME}"
fi

if [ ! -d "$FASTQ_DIR" ]; then
    echo -e "${RED}エラー: ディレクトリが存在しません: $FASTQ_DIR${NC}"
    exit 1
fi

echo -e "${GREEN}選択されたFASTQディレクトリ: ${FASTQ_DIR}${NC}"

# タイムスタンプを生成
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 出力ディレクトリを自動生成
mkdir -p "$OUTPUT_BASE_DIR"
OUTPUT_DIR="${OUTPUT_BASE_DIR}/output_${FASTQ_DIRNAME}_${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"
echo -e "${GREEN}出力ディレクトリ: ${OUTPUT_DIR}${NC}"

# スレッド数
echo ""
echo -e "${YELLOW}ヒント: 使用可能なCPU数に応じて設定（多いほど高速、メモリ使用量も増加）${NC}"
echo -e "${YELLOW}  推奨: 8〜16（サーバースペックに応じて調整）${NC}"
read -p "使用するCPUスレッド数 [デフォルト: 8]: " THREADS
THREADS=${THREADS:-8}

# 生物種の確認
echo ""
echo -e "${YELLOW}ヒント: 解析対象の生物種名（記録用）${NC}"
read -p "生物種 [デフォルト: Drosophila]: " SPECIES
SPECIES=${SPECIES:-Drosophila}
echo "  → 生物種: $SPECIES"

################################################################################
# リファレンスファイルの自動検出（srcディレクトリから）
################################################################################

echo ""
echo -e "${GREEN}[2] リファレンスファイルの自動検出${NC}"

# STAR インデックス（srcディレクトリ内を自動検出）
DEFAULT_STAR_INDEX=""
STAR_INDEXES=()
for dir in "${SRC_DIR}"/STAR_index* "${SRC_DIR}"/star_index* "${SRC_DIR}"/*_STAR_index "${SRC_DIR}"/*STAR*; do
    if [ -d "$dir" ] && [ -f "$dir/Genome" ] && [ -f "$dir/SA" ]; then
        STAR_INDEXES+=("$dir")
        if [ -z "$DEFAULT_STAR_INDEX" ]; then
            DEFAULT_STAR_INDEX="$dir"
        fi
    fi
done

if [ ${#STAR_INDEXES[@]} -gt 0 ]; then
    echo -e "${GREEN}STARインデックスを検出:${NC}"
    for i in "${!STAR_INDEXES[@]}"; do
        echo "  $((i+1)). $(basename "${STAR_INDEXES[$i]}")"
    done
    if [ ${#STAR_INDEXES[@]} -eq 1 ]; then
        STAR_INDEX="$DEFAULT_STAR_INDEX"
        echo -e "${GREEN}  → 自動選択: $(basename "$STAR_INDEX")${NC}"
    else
        read -p "使用するインデックス番号 [デフォルト: 1]: " STAR_IDX
        STAR_IDX=${STAR_IDX:-1}
        STAR_INDEX="${STAR_INDEXES[$((STAR_IDX-1))]}"
    fi
else
    echo -e "${YELLOW}STARインデックスが見つかりません${NC}"
    read -p "STARゲノムインデックスのパス: " STAR_INDEX
fi

if [ ! -d "$STAR_INDEX" ]; then
    echo -e "${RED}エラー: STARインデックスが存在しません: $STAR_INDEX${NC}"
    exit 1
fi
echo "  STARインデックス: $STAR_INDEX"

# GTFファイル（srcディレクトリ内を自動検出）
DEFAULT_GTF_FILE=""
GTF_FILES=()
for gtf in "${SRC_DIR}"/*.gtf "${SRC_DIR}"/*.gtf.gz; do
    if [ -f "$gtf" ]; then
        GTF_FILES+=("$gtf")
        if [ -z "$DEFAULT_GTF_FILE" ]; then
            DEFAULT_GTF_FILE="$gtf"
        fi
    fi
done

if [ ${#GTF_FILES[@]} -gt 0 ]; then
    echo -e "${GREEN}GTFファイルを検出:${NC}"
    for i in "${!GTF_FILES[@]}"; do
        echo "  $((i+1)). $(basename "${GTF_FILES[$i]}")"
    done
    if [ ${#GTF_FILES[@]} -eq 1 ]; then
        GTF_FILE="$DEFAULT_GTF_FILE"
        echo -e "${GREEN}  → 自動選択: $(basename "$GTF_FILE")${NC}"
    else
        read -p "使用するGTF番号 [デフォルト: 1]: " GTF_IDX
        GTF_IDX=${GTF_IDX:-1}
        GTF_FILE="${GTF_FILES[$((GTF_IDX-1))]}"
    fi
else
    echo -e "${YELLOW}GTFファイルが見つかりません${NC}"
    read -p "GTFファイルのパス: " GTF_FILE
fi

if [ ! -f "$GTF_FILE" ]; then
    echo -e "${RED}エラー: GTFファイルが存在しません: $GTF_FILE${NC}"
    exit 1
fi
echo "  GTFファイル: $GTF_FILE"

# ゲノムFASTAファイル（srcディレクトリ内を自動検出、記録用）
GENOME_FASTA=""
for fa in "${SRC_DIR}"/*.fa "${SRC_DIR}"/*.fasta "${SRC_DIR}"/*.fa.gz; do
    if [ -f "$fa" ]; then
        GENOME_FASTA="$fa"
        break
    fi
done
if [ -n "$GENOME_FASTA" ]; then
    echo "  FASTAファイル: $GENOME_FASTA"
fi

# シングルエンド/ペアエンドの自動検出（確認なし）
echo ""
echo -e "${GREEN}[3] シーケンスタイプの自動検出${NC}"

# ペアエンドファイル（_R1/_R2 または _1/_2パターン）を検出
PE_R1_COUNT=$(ls -1 "$FASTQ_DIR"/*_R1.fastq.gz "$FASTQ_DIR"/*_R1.fq.gz 2>/dev/null | wc -l)
PE_1_COUNT=$(ls -1 "$FASTQ_DIR"/*_1.fastq.gz "$FASTQ_DIR"/*_1.fq.gz 2>/dev/null | wc -l)
PE_COUNT=$((PE_R1_COUNT + PE_1_COUNT))

# 自動判定：_R1/_R2または_1/_2パターンがあればペアエンド
if [ "$PE_COUNT" -gt 0 ]; then
    IS_PAIRED_END=true
    echo -e "${GREEN}  → 自動検出: ペアエンド (PE) - ${PE_COUNT} ペア${NC}"
else
    IS_PAIRED_END=false
    TOTAL_FILES=$(ls -1 "$FASTQ_DIR"/*.fastq.gz "$FASTQ_DIR"/*.fq.gz 2>/dev/null | wc -l)
    echo -e "${GREEN}  → 自動検出: シングルエンド (SE) - ${TOTAL_FILES} ファイル${NC}"
fi

# Trimmomatic アダプターファイル
echo ""
if [ "$IS_PAIRED_END" = true ]; then
    DEFAULT_ADAPTER_NAME="TruSeq3-PE-2.fa"
else
    DEFAULT_ADAPTER_NAME="TruSeq3-SE.fa"
fi

if [ -n "$TRIMMOMATIC_ADAPTER_DIR" ] && [ -d "$TRIMMOMATIC_ADAPTER_DIR" ]; then
    DEFAULT_ADAPTER="${TRIMMOMATIC_ADAPTER_DIR}/${DEFAULT_ADAPTER_NAME}"
else
    DEFAULT_ADAPTER="$DEFAULT_ADAPTER_NAME"
fi
echo "  アダプターファイル: $DEFAULT_ADAPTER"
ADAPTER_FILE="$DEFAULT_ADAPTER"

################################################################################
# サンプル情報の収集
################################################################################

echo ""
echo -e "${GREEN}[4] サンプル情報の収集${NC}"
echo "FASTQファイルを検索中..."

SAMPLE_LIST=()

if [ "$IS_PAIRED_END" = true ]; then
    # ペアエンドモード
    for R1_FILE in "$FASTQ_DIR"/*_R1.fastq.gz "$FASTQ_DIR"/*_R1.fq.gz "$FASTQ_DIR"/*_1.fastq.gz "$FASTQ_DIR"/*_1.fq.gz; do
        if [ -f "$R1_FILE" ]; then
            BASENAME=$(basename "$R1_FILE" | sed -E 's/_(R)?1\.(fastq|fq)\.gz$//')
            SAMPLE_LIST+=("$BASENAME")
        fi
    done
else
    # シングルエンドモード
    for FASTQ_FILE in "$FASTQ_DIR"/*.fastq.gz "$FASTQ_DIR"/*.fq.gz; do
        if [ -f "$FASTQ_FILE" ]; then
            BASENAME=$(basename "$FASTQ_FILE" | sed -E 's/\.(fastq|fq)\.gz$//')
            # _R1/_R2 や _1/_2 が付いている場合は除外
            if [[ ! "$BASENAME" =~ _(R)?[12]$ ]]; then
                SAMPLE_LIST+=("$BASENAME")
            fi
        fi
    done
fi

if [ ${#SAMPLE_LIST[@]} -eq 0 ]; then
    echo -e "${RED}エラー: FASTQファイルが見つかりません${NC}"
    echo ""
    echo -e "${YELLOW}=== FASTQファイル命名規則 ===${NC}"
    echo ""
    echo "ペアエンドの場合:"
    echo "  サンプル名_R1.fastq.gz / サンプル名_R2.fastq.gz"
    echo "  サンプル名_1.fastq.gz  / サンプル名_2.fastq.gz"
    echo ""
    echo "シングルエンドの場合:"
    echo "  サンプル名.fastq.gz"
    echo ""
    echo "例:"
    echo "  ペアエンド:   Control_rep1_R1.fastq.gz, Control_rep1_R2.fastq.gz"
    echo "  シングルエンド: Control_rep1.fastq.gz"
    echo ""
    echo "注意:"
    echo "  - ファイル名にスペースや特殊文字を含めない"
    echo "  - .gz圧縮が必要"
    echo ""
    exit 1
fi

echo ""
echo -e "${GREEN}検出されたサンプル: ${#SAMPLE_LIST[@]}件${NC}"
echo ""
echo "  No.  サンプル名"
echo "  ---- --------------------------"
for i in "${!SAMPLE_LIST[@]}"; do
    printf "  %-4s %s\n" "$((i+1))." "${SAMPLE_LIST[$i]}"
done

################################################################################
# 実験群の設定
################################################################################

echo ""
echo -e "${GREEN}[5] 実験群の設定${NC}"
echo ""
echo -e "${YELLOW}ヒント: 比較したいグループの数を入力${NC}"
read -p "グループ数: " NUM_GROUPS

if ! [[ "$NUM_GROUPS" =~ ^[0-9]+$ ]] || [ "$NUM_GROUPS" -lt 2 ]; then
    echo -e "${RED}エラー: グループ数は2以上の整数で入力してください${NC}"
    exit 1
fi

declare -A SAMPLE_GROUPS
GROUP_NAMES=()

for ((g=1; g<=NUM_GROUPS; g++)); do
    echo ""
    echo -e "${BLUE}--- グループ ${g}/${NUM_GROUPS} の設定 ---${NC}"
    read -p "グループ${g}の名前: " GROUP_NAME

    if [[ "$GROUP_NAME" =~ [[:space:]] ]] || [[ -z "$GROUP_NAME" ]]; then
        echo -e "${RED}エラー: グループ名にスペースを含めないでください${NC}"
        exit 1
    fi

    GROUP_NAMES+=("$GROUP_NAME")

    echo ""
    echo "グループ '${GROUP_NAME}' に含めるサンプルを選択"
    echo -e "${YELLOW}ヒント: 番号をカンマ区切りで入力（例: 1,2）${NC}"
    echo ""
    for i in "${!SAMPLE_LIST[@]}"; do
        CURRENT_GROUP=${SAMPLE_GROUPS["${SAMPLE_LIST[$i]}"]}
        if [ -n "$CURRENT_GROUP" ]; then
            printf "  %-4s %-30s [%s]\n" "$((i+1))." "${SAMPLE_LIST[$i]}" "$CURRENT_GROUP"
        else
            printf "  %-4s %-30s (未割り当て)\n" "$((i+1))." "${SAMPLE_LIST[$i]}"
        fi
    done
    echo ""
    read -p "サンプル番号: " SAMPLE_INDICES

    IFS=',' read -ra INDICES <<< "$SAMPLE_INDICES"
    for idx in "${INDICES[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        idx=$((idx-1))
        if [ $idx -ge 0 ] && [ $idx -lt ${#SAMPLE_LIST[@]} ]; then
            SAMPLE_GROUPS["${SAMPLE_LIST[$idx]}"]="$GROUP_NAME"
            echo -e "  ${GREEN}✓ ${SAMPLE_LIST[$idx]} → $GROUP_NAME${NC}"
        fi
    done
done

# サンプル情報ファイルの作成
SAMPLE_INFO="$OUTPUT_DIR/sample_info.txt"
echo -e "SampleID\tGroup" > "$SAMPLE_INFO"
for SAMPLE in "${SAMPLE_LIST[@]}"; do
    GROUP=${SAMPLE_GROUPS[$SAMPLE]:-"Unassigned"}
    echo -e "$SAMPLE\t$GROUP" >> "$SAMPLE_INFO"
done

# グループ-サンプル対応表の表示
echo ""
echo -e "${GREEN}=== グループ-サンプル対応表 ===${NC}"
for gname in "${GROUP_NAMES[@]}"; do
    echo -e "${BLUE}[$gname]${NC}"
    for SAMPLE in "${SAMPLE_LIST[@]}"; do
        if [ "${SAMPLE_GROUPS[$SAMPLE]}" = "$gname" ]; then
            echo "  - $SAMPLE"
        fi
    done
done

# 未割り当てサンプルの警告
UNASSIGNED_SAMPLES=()
for SAMPLE in "${SAMPLE_LIST[@]}"; do
    if [ -z "${SAMPLE_GROUPS[$SAMPLE]}" ]; then
        UNASSIGNED_SAMPLES+=("$SAMPLE")
    fi
done
if [ ${#UNASSIGNED_SAMPLES[@]} -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}⚠ 警告: 以下のサンプルはどのグループにも割り当てられていません:${NC}"
    for s in "${UNASSIGNED_SAMPLES[@]}"; do
        echo -e "${YELLOW}  - $s${NC}"
    done
    echo -e "${YELLOW}  これらのサンプルは解析から除外されます。${NC}"
fi

# レプリケート不足の警告
LOW_REP_GROUPS=()
for gname in "${GROUP_NAMES[@]}"; do
    count=0
    for SAMPLE in "${SAMPLE_LIST[@]}"; do
        if [ "${SAMPLE_GROUPS[$SAMPLE]}" = "$gname" ]; then
            count=$((count + 1))
        fi
    done
    if [ "$count" -lt 2 ]; then
        LOW_REP_GROUPS+=("$gname (n=$count)")
    fi
done
if [ ${#LOW_REP_GROUPS[@]} -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}⚠ 警告: 以下のグループはレプリケートが不足しています（サンプル数 < 2）:${NC}"
    for g in "${LOW_REP_GROUPS[@]}"; do
        echo -e "${YELLOW}  - $g${NC}"
    done
    echo -e "${YELLOW}  統計的信頼性が低下し、BCVプロットは出力されません。${NC}"
    echo -e "${YELLOW}  可能であれば各グループに2つ以上のサンプルを割り当てることを推奨します。${NC}"
fi

################################################################################
################################################################################
# 比較ペアの設定
################################################################################

echo ""
echo -e "${GREEN}[6] 比較ペアの設定${NC}"

COMPARISONS=()

if [ "$NUM_GROUPS" -eq 2 ]; then
    COMP="${GROUP_NAMES[0]}-${GROUP_NAMES[1]}"
    COMPARISONS+=("$COMP")
    echo -e "${GREEN}比較: $COMP${NC}"
else
    echo "比較ペアを設定します（任意の2群を選択）"
    echo ""
    
    while true; do
        echo "=== 比較ペア $((${#COMPARISONS[@]}+1)) ==="
        echo "グループ一覧:"
        for i in "${!GROUP_NAMES[@]}"; do
            echo "  $((i+1)). ${GROUP_NAMES[$i]}"
        done
        echo ""
        
        read -p "対照群（Control）の番号: " CTRL_IDX
        if [[ ! "$CTRL_IDX" =~ ^[0-9]+$ ]] || [ "$CTRL_IDX" -lt 1 ] || [ "$CTRL_IDX" -gt "$NUM_GROUPS" ]; then
            echo "無効な番号です"
            continue
        fi
        CTRL_GROUP="${GROUP_NAMES[$((CTRL_IDX-1))]}"
        
        read -p "実験群（Treatment）の番号: " TREAT_IDX
        if [[ ! "$TREAT_IDX" =~ ^[0-9]+$ ]] || [ "$TREAT_IDX" -lt 1 ] || [ "$TREAT_IDX" -gt "$NUM_GROUPS" ]; then
            echo "無効な番号です"
            continue
        fi
        if [ "$TREAT_IDX" -eq "$CTRL_IDX" ]; then
            echo "同じグループは選択できません"
            continue
        fi
        TREAT_GROUP="${GROUP_NAMES[$((TREAT_IDX-1))]}"
        
        COMP="${CTRL_GROUP}-${TREAT_GROUP}"
        
        if [[ " ${COMPARISONS[*]} " =~ " ${COMP} " ]]; then
            echo "この比較は既に追加されています"
        else
            COMPARISONS+=("$COMP")
            echo -e "  ${GREEN}✓ $COMP を追加${NC}"
        fi
        
        echo ""
        echo "現在の比較ペア:"
        for c in "${COMPARISONS[@]}"; do
            echo "  - $c"
        done
        echo ""
        
        read -p "さらに比較を追加しますか？ (y/n) [n]: " ADD_MORE
        ADD_MORE=${ADD_MORE:-n}
        if [[ "$ADD_MORE" != "y" && "$ADD_MORE" != "Y" ]]; then
            break
        fi
        echo ""
    done
fi

if [ ${#COMPARISONS[@]} -eq 0 ]; then
    echo -e "${RED}エラー: 比較ペアが設定されていません${NC}"
    exit 1
fi

COMPARISON=$(IFS=','; echo "${COMPARISONS[*]}")

COMPARISON=$(IFS=','; echo "${COMPARISONS[*]}")

################################################################################
# 設定確認
################################################################################

echo ""
echo -e "${GREEN}=== 設定確認 ===${NC}"
echo ""
echo "  生物種:           $SPECIES"
echo "  FASTQディレクトリ: $FASTQ_DIR"
echo "  出力ディレクトリ:  $OUTPUT_DIR"
echo "  スレッド数:        $THREADS"
echo "  シーケンスタイプ:  $([ "$IS_PAIRED_END" = true ] && echo "ペアエンド" || echo "シングルエンド")"
echo "  STARインデックス:  $STAR_INDEX"
echo "  GTFファイル:       $GTF_FILE"
echo ""
echo "  サンプル数:        ${#SAMPLE_LIST[@]}"
echo "  グループ:          ${GROUP_NAMES[*]}"
echo "  比較:              ${COMPARISONS[*]}"
echo ""
read -p "この設定で実行しますか？ (yes/no): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
    echo "中止しました"
    exit 0
fi

################################################################################
# ディレクトリ構造の作成
################################################################################

echo ""
echo -e "${GREEN}[7] ディレクトリ構造を作成中...${NC}"

FASTQC_RAW_DIR="$OUTPUT_DIR/01_fastqc_raw"
TRIMMED_DIR="$OUTPUT_DIR/02_trimmed"
FASTQC_TRIMMED_DIR="$OUTPUT_DIR/03_fastqc_trimmed"
STAR_DIR="$OUTPUT_DIR/04_star_aligned"
COUNTS_DIR="$OUTPUT_DIR/05_counts"
EDGER_DIR="$OUTPUT_DIR/06_edgeR"
MULTIQC_DIR="$OUTPUT_DIR/07_multiqc"

mkdir -p "$FASTQC_RAW_DIR" "$TRIMMED_DIR" "$FASTQC_TRIMMED_DIR" "$STAR_DIR" "$COUNTS_DIR" "$EDGER_DIR" "$MULTIQC_DIR"

################################################################################
# パイプライン実行
################################################################################

LOG_FILE="$OUTPUT_DIR/pipeline.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo ""
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}  RNA-seq パイプライン開始${NC}"
echo -e "${BLUE}  生物種: $SPECIES${NC}"
echo -e "${BLUE}  開始時刻: $(date)${NC}"
echo -e "${BLUE}======================================${NC}"

# FastQC (Raw)
echo ""
echo -e "${GREEN}[8] FastQC（生データ）を実行中...${NC}"
for SAMPLE in "${SAMPLE_LIST[@]}"; do
    if [ "$IS_PAIRED_END" = true ]; then
        R1=$(find "$FASTQ_DIR" \( -name "${SAMPLE}*R1*.fastq.gz" -o -name "${SAMPLE}*_1.fastq.gz" \) 2>/dev/null | head -n 1)
        R2=$(find "$FASTQ_DIR" \( -name "${SAMPLE}*R2*.fastq.gz" -o -name "${SAMPLE}*_2.fastq.gz" \) 2>/dev/null | head -n 1)
        echo "  処理中: $SAMPLE (PE)"
        fastqc -t 2 -o "$FASTQC_RAW_DIR" "$R1" "$R2"
    else
        FASTQ=$(find "$FASTQ_DIR" -name "${SAMPLE}.fastq.gz" 2>/dev/null | head -n 1)
        echo "  処理中: $SAMPLE (SE)"
        fastqc -t 2 -o "$FASTQC_RAW_DIR" "$FASTQ"
    fi
done
echo -e "${GREEN}FastQC（生データ）完了${NC}"

# Trimmomatic
echo ""
echo -e "${GREEN}[9] Trimmomatic（品質フィルタリング）を実行中...${NC}"
for SAMPLE in "${SAMPLE_LIST[@]}"; do
    if [ "$IS_PAIRED_END" = true ]; then
        R1=$(find "$FASTQ_DIR" \( -name "${SAMPLE}*R1*.fastq.gz" -o -name "${SAMPLE}*_1.fastq.gz" \) 2>/dev/null | head -n 1)
        R2=$(find "$FASTQ_DIR" \( -name "${SAMPLE}*R2*.fastq.gz" -o -name "${SAMPLE}*_2.fastq.gz" \) 2>/dev/null | head -n 1)
        echo "  処理中: $SAMPLE (PE)"
        export _JAVA_OPTIONS="-Xmx32G"
        trimmomatic PE -threads $THREADS \
            "$R1" "$R2" \
            "$TRIMMED_DIR/${SAMPLE}_R1_paired.fastq.gz" \
            "$TRIMMED_DIR/${SAMPLE}_R1_unpaired.fastq.gz" \
            "$TRIMMED_DIR/${SAMPLE}_R2_paired.fastq.gz" \
            "$TRIMMED_DIR/${SAMPLE}_R2_unpaired.fastq.gz" \
            ILLUMINACLIP:${ADAPTER_FILE}:2:30:10 \
            LEADING:3 TRAILING:3 SLIDINGWINDOW:4:15 MINLEN:36
    else
        FASTQ=$(find "$FASTQ_DIR" -name "${SAMPLE}.fastq.gz" 2>/dev/null | head -n 1)
        echo "  処理中: $SAMPLE (SE)"
        trimmomatic SE -threads $THREADS \
            "$FASTQ" \
            "$TRIMMED_DIR/${SAMPLE}_trimmed.fastq.gz" \
            ILLUMINACLIP:${ADAPTER_FILE}:2:30:10 \
            LEADING:3 TRAILING:3 SLIDINGWINDOW:4:15 MINLEN:36
    fi
done
echo -e "${GREEN}Trimmomatic完了${NC}"

# FastQC (Trimmed)
echo ""
echo -e "${GREEN}[10] FastQC（トリミング後）を実行中...${NC}"
for SAMPLE in "${SAMPLE_LIST[@]}"; do
    if [ "$IS_PAIRED_END" = true ]; then
        echo "  処理中: $SAMPLE (PE)"
        fastqc -t 2 -o "$FASTQC_TRIMMED_DIR" \
            "$TRIMMED_DIR/${SAMPLE}_R1_paired.fastq.gz" \
            "$TRIMMED_DIR/${SAMPLE}_R2_paired.fastq.gz"
    else
        echo "  処理中: $SAMPLE (SE)"
        fastqc -t 2 -o "$FASTQC_TRIMMED_DIR" \
            "$TRIMMED_DIR/${SAMPLE}_trimmed.fastq.gz"
    fi
done
echo -e "${GREEN}FastQC（トリミング後）完了${NC}"

# STAR mapping
echo ""
echo -e "${GREEN}[11] STAR（アライメント）を実行中...${NC}"
for SAMPLE in "${SAMPLE_LIST[@]}"; do
    echo "  処理中: $SAMPLE"

    if [ "$IS_PAIRED_END" = true ]; then
        STAR --runThreadN $THREADS \
            --genomeDir "$STAR_INDEX" \
            --readFilesIn "$TRIMMED_DIR/${SAMPLE}_R1_paired.fastq.gz" "$TRIMMED_DIR/${SAMPLE}_R2_paired.fastq.gz" \
            --readFilesCommand zcat \
            --sjdbGTFfile "$GTF_FILE" \
            --outFileNamePrefix "$STAR_DIR/${SAMPLE}_" \
            --outSAMtype BAM SortedByCoordinate \
            --outSAMunmapped Within \
            --outSAMattributes Standard
    else
        STAR --runThreadN $THREADS \
            --genomeDir "$STAR_INDEX" \
            --readFilesIn "$TRIMMED_DIR/${SAMPLE}_trimmed.fastq.gz" \
            --readFilesCommand zcat \
            --sjdbGTFfile "$GTF_FILE" \
            --outFileNamePrefix "$STAR_DIR/${SAMPLE}_" \
            --outSAMtype BAM SortedByCoordinate \
            --outSAMunmapped Within \
            --outSAMattributes Standard
    fi

    if [ -f "$STAR_DIR/${SAMPLE}_Log.final.out" ]; then
        echo "  → $(grep 'Uniquely mapped reads number' "$STAR_DIR/${SAMPLE}_Log.final.out" | cut -f2)"
    fi
done
echo -e "${GREEN}STARアライメント完了${NC}"

# featureCounts
echo ""
echo -e "${GREEN}[12] featureCounts（カウント定量）を実行中...${NC}"

BAM_FILES=()
for SAMPLE in "${SAMPLE_LIST[@]}"; do
    BAM_FILES+=("$STAR_DIR/${SAMPLE}_Aligned.sortedByCoord.out.bam")
done

if [ "$IS_PAIRED_END" = true ]; then
    featureCounts -T $THREADS -p -B -C -a "$GTF_FILE" -o "$COUNTS_DIR/gene_counts.txt" "${BAM_FILES[@]}"
else
    featureCounts -T $THREADS -a "$GTF_FILE" -o "$COUNTS_DIR/gene_counts.txt" "${BAM_FILES[@]}"
fi
echo -e "${GREEN}featureCounts完了${NC}"

# MultiQC
echo ""
echo -e "${GREEN}[13] MultiQC（統合レポート）を生成中...${NC}"
multiqc "$OUTPUT_DIR" -o "$MULTIQC_DIR" -n multiqc_report.html --force
echo -e "${GREEN}MultiQC完了${NC}"

# edgeR解析
echo ""
echo -e "${GREEN}[14] edgeR（差次発現解析）を実行中...${NC}"

cat > "$EDGER_DIR/run_edgeR.R" << 'RSCRIPT'
#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
counts_file <- args[1]
sample_info_file <- args[2]
output_dir <- args[3]
comparisons_str <- args[4]
gtf_file <- args[5]

library(edgeR)
library(ggplot2)

cat("===========================================\n")
cat("  edgeR 差次発現解析 (TPM-based)\n")
cat("===========================================\n\n")

# GTFファイルから遺伝子ID→遺伝子名と遺伝子長のマッピングを作成
cat("GTFファイルから遺伝子情報を読み込み中...\n")
gtf_lines <- readLines(gtf_file)
gtf_lines <- gtf_lines[!grepl("^#", gtf_lines)]

# exonから遺伝子長を計算
exon_lines <- gtf_lines[grepl("\texon\t", gtf_lines)]

parse_exon <- function(line) {
  fields <- strsplit(line, "\t")[[1]]
  start <- as.numeric(fields[4])
  end <- as.numeric(fields[5])
  attrs <- fields[9]
  gene_id <- sub('.*gene_id "([^"]+)".*', "\\1", attrs)
  c(gene_id, start, end)
}

if (length(exon_lines) > 0) {
  exon_info <- t(sapply(exon_lines, parse_exon))
  exon_df <- data.frame(
    gene_id = exon_info[,1],
    start = as.numeric(exon_info[,2]),
    end = as.numeric(exon_info[,3]),
    stringsAsFactors = FALSE
  )
  # 遺伝子ごとの総exon長を計算（重複を考慮した簡易版）
  gene_lengths <- aggregate(cbind(length = end - start + 1) ~ gene_id, data = exon_df, FUN = sum)
} else {
  # exonがない場合はgeneエントリから長さを取得
  gene_entries <- gtf_lines[grepl("\tgene\t", gtf_lines)]
  parse_gene_length <- function(line) {
    fields <- strsplit(line, "\t")[[1]]
    start <- as.numeric(fields[4])
    end <- as.numeric(fields[5])
    attrs <- fields[9]
    gene_id <- sub('.*gene_id "([^"]+)".*', "\\1", attrs)
    c(gene_id, end - start + 1)
  }
  gene_len_info <- t(sapply(gene_entries, parse_gene_length))
  gene_lengths <- data.frame(
    gene_id = gene_len_info[,1],
    length = as.numeric(gene_len_info[,2]),
    stringsAsFactors = FALSE
  )
}
rownames(gene_lengths) <- gene_lengths$gene_id

# 遺伝子名のマッピング
gene_lines <- gtf_lines[grepl("\tgene\t", gtf_lines)]
parse_gtf_attr <- function(line) {
  attrs <- strsplit(line, "\t")[[1]][9]
  gene_id <- sub('.*gene_id "([^"]+)".*', "\\1", attrs)
  gene_name <- sub('.*gene_name "([^"]+)".*', "\\1", attrs)
  if (gene_name == attrs) gene_name <- gene_id
  c(gene_id, gene_name)
}

gene_info <- t(sapply(gene_lines, parse_gtf_attr))
gene_map <- data.frame(
  gene_id = gene_info[,1],
  gene_name = gene_info[,2],
  stringsAsFactors = FALSE
)
gene_map <- gene_map[!duplicated(gene_map$gene_id), ]
rownames(gene_map) <- gene_map$gene_id
cat("  遺伝子数:", nrow(gene_map), "\n")
cat("  遺伝子長情報:", nrow(gene_lengths), "遺伝子\n\n")

# カウントデータの読み込み
counts <- read.table(counts_file, header = TRUE, row.names = 1, skip = 1)
counts <- counts[, 6:ncol(counts)]
extract_sample <- function(x) {
  parts <- strsplit(x, "_Aligned")[[1]][1]
  segments <- strsplit(parts, "[./]")[[1]]
  segments[length(segments)]
}
colnames(counts) <- sapply(colnames(counts), extract_sample)

sample_info <- read.table(sample_info_file, header = TRUE, sep = "\t")
sample_info <- sample_info[match(colnames(counts), sample_info$SampleID), ]

cat("サンプル数:", ncol(counts), "\n")
cat("グループ:", paste(unique(sample_info$Group), collapse = ", "), "\n\n")

# TPM計算関数
calculate_tpm <- function(counts_matrix, gene_lengths_df) {
  # 共通する遺伝子のみ使用
  common_genes <- intersect(rownames(counts_matrix), rownames(gene_lengths_df))
  counts_sub <- counts_matrix[common_genes, , drop = FALSE]
  lengths <- gene_lengths_df[common_genes, "length"]

  # RPK (Reads Per Kilobase)
  rpk <- counts_sub / (lengths / 1000)

  # TPM
  tpm <- t(t(rpk) / colSums(rpk) * 1e6)

  return(tpm)
}

# TPM計算
cat("TPMを計算中...\n")
tpm_matrix <- calculate_tpm(counts, gene_lengths)
cat("  TPM計算完了:", nrow(tpm_matrix), "遺伝子\n\n")

# TPMデータにgene_nameを追加して保存
tpm_output <- as.data.frame(tpm_matrix)
tpm_output$gene_id <- rownames(tpm_output)
tpm_output$gene_name <- gene_map[rownames(tpm_output), "gene_name"]
tpm_output$gene_name[is.na(tpm_output$gene_name)] <- tpm_output$gene_id[is.na(tpm_output$gene_name)]
tpm_output <- tpm_output[, c("gene_name", "gene_id", setdiff(colnames(tpm_output), c("gene_name", "gene_id")))]
write.csv(tpm_output, file = file.path(output_dir, "TPM_all_samples.csv"), row.names = FALSE)
cat("TPMデータを保存:", file.path(output_dir, "TPM_all_samples.csv"), "\n\n")

# edgeR解析（フィルタリングと正規化）
y <- DGEList(counts = counts, group = sample_info$Group)
keep <- filterByExpr(y)
y <- y[keep, , keep.lib.sizes = FALSE]
cat("フィルタリング後の遺伝子数:", nrow(y), "\n\n")

y <- calcNormFactors(y)
design <- model.matrix(~0 + group, data = y$samples)
colnames(design) <- levels(y$samples$group)

# レプリケートの有無を判定
group_counts <- table(y$samples$group)
has_replicates <- all(group_counts >= 2)

if (has_replicates) {
  cat("レプリケートあり: 通常の分散推定を実行\n")
  y <- estimateDisp(y, design)
  fit <- glmQLFit(y, design)
  use_exact_test <- FALSE
} else {
  cat("レプリケートなし: 固定BCV=0.4を使用\n")
  cat("注意: p値は参考値としてご利用ください\n\n")
  bcv <- 0.4
  use_exact_test <- TRUE
}

# フィルタリング後のTPMも保存
tpm_filtered <- tpm_matrix[rownames(y), , drop = FALSE]

# MDS plot（サンプル数3以上の場合のみ）
n_samples <- ncol(y)
if (n_samples >= 3) {
  pdf(file.path(output_dir, "MDS_plot.pdf"), width = 8, height = 6)
  plotMDS(y, col = as.numeric(y$samples$group), pch = 16, cex = 1.5)
  legend("topright", legend = levels(y$samples$group), col = 1:nlevels(y$samples$group), pch = 16)
  title("MDS Plot - Sample Distance")
  dev.off()
  cat("MDSプロット保存完了\n")
} else {
  cat("注意: サンプル数が少ないためMDSプロットはスキップされました\n")
}

# PCA plot (TPMベース、サンプル数3以上の場合のみ)
n_samples <- ncol(tpm_filtered)
if (n_samples >= 3) {
  cat("PCA解析を実行中 (TPMベース)...\n")
  log_tpm <- log2(tpm_filtered + 1)
  pca_result <- prcomp(t(log_tpm), scale. = TRUE, center = TRUE)
  pca_df <- data.frame(
    PC1 = pca_result$x[,1],
    PC2 = pca_result$x[,2],
    Sample = rownames(pca_result$x),
    Group = sample_info$Group
  )
  var_explained <- summary(pca_result)$importance[2,] * 100

  # PCA plot保存
  pdf(file.path(output_dir, "PCA_plot_TPM.pdf"), width = 10, height = 8)
  p_pca <- ggplot(pca_df, aes(x = PC1, y = PC2, color = Group, label = Sample)) +
    geom_point(size = 4) +
    geom_text(vjust = -1, hjust = 0.5, size = 3) +
    theme_minimal() +
    labs(
      title = "PCA Plot (TPM-based, log2 transformed)",
      x = paste0("PC1 (", round(var_explained[1], 1), "%)"),
      y = paste0("PC2 (", round(var_explained[2], 1), "%)")
    ) +
    theme(
      plot.title = element_text(hjust = 0.5, size = 14),
      legend.position = "right"
    )
  print(p_pca)
  dev.off()

  # PC1-3のPCAプロットも保存（3群以上の場合に有用）
  if (ncol(pca_result$x) >= 3) {
    pca_df$PC3 <- pca_result$x[,3]

    pdf(file.path(output_dir, "PCA_plot_TPM_PC1_PC3.pdf"), width = 10, height = 8)
    p_pca13 <- ggplot(pca_df, aes(x = PC1, y = PC3, color = Group, label = Sample)) +
      geom_point(size = 4) +
      geom_text(vjust = -1, hjust = 0.5, size = 3) +
      theme_minimal() +
      labs(
        title = "PCA Plot PC1 vs PC3 (TPM-based)",
        x = paste0("PC1 (", round(var_explained[1], 1), "%)"),
        y = paste0("PC3 (", round(var_explained[3], 1), "%)")
      ) +
      theme(plot.title = element_text(hjust = 0.5, size = 14))
    print(p_pca13)
    dev.off()
  }
  cat("PCA plot保存完了\n\n")
} else {
  cat("注意: サンプル数が少ないためPCAプロットはスキップされました\n\n")
}

# BCV plot（レプリケートがある場合のみ）
if (has_replicates) {
  pdf(file.path(output_dir, "BCV_plot.pdf"), width = 8, height = 6)
  plotBCV(y)
  title("Biological Coefficient of Variation")
  dev.off()
  cat("BCVプロット保存完了\n")
} else {
  cat("注意: レプリケートがないためBCVプロットはスキップされました\n")
}

# 比較解析
comparisons <- unlist(strsplit(comparisons_str, ","))
summary_results <- data.frame(Comparison = character(), Total_Genes = integer(),
    Significant_FDR005 = integer(), Up_regulated = integer(), Down_regulated = integer(),
    stringsAsFactors = FALSE)

for (comparison in comparisons) {
    cat("比較:", comparison, "\n")
    comp_parts <- unlist(strsplit(comparison, "-"))
    if (length(comp_parts) != 2) next
    if (!(comp_parts[1] %in% colnames(design)) || !(comp_parts[2] %in% colnames(design))) next
    # edgeRの統計検定（レプリケートの有無で分岐）
    if (use_exact_test) {
      # レプリケートなし: exactTest with fixed dispersion
      et <- exactTest(y, pair = c(comp_parts[1], comp_parts[2]), dispersion = bcv^2)
      res <- topTags(et, n = Inf)
    } else {
      # レプリケートあり: glmQLFTest
      contrast_str <- paste0(comp_parts[2], "-", comp_parts[1])
      my_contrast <- makeContrasts(contrasts = contrast_str, levels = design)
      qlf <- glmQLFTest(fit, contrast = my_contrast)
      res <- topTags(qlf, n = Inf)
    }

    # グループごとのサンプルインデックス
    group1_samples <- sample_info$SampleID[sample_info$Group == comp_parts[1]]
    group2_samples <- sample_info$SampleID[sample_info$Group == comp_parts[2]]

    # TPMベースのFold Change計算
    tpm_common <- tpm_filtered[rownames(res$table), , drop = FALSE]
    mean_tpm_group1 <- rowMeans(tpm_common[, group1_samples, drop = FALSE])
    mean_tpm_group2 <- rowMeans(tpm_common[, group2_samples, drop = FALSE])

    # TPM FC (log2)を計算（0除算対策として小さい値を追加）
    pseudo_count <- 0.01
    tpm_log2FC <- log2((mean_tpm_group2 + pseudo_count) / (mean_tpm_group1 + pseudo_count))

    # 結果テーブルの作成（TPMベースのみ、CPMベースは除外）
    res_table <- data.frame(gene_id = rownames(res$table), stringsAsFactors = FALSE)
    res_table$gene_name <- gene_map[res_table$gene_id, "gene_name"]
    res_table$gene_name[is.na(res_table$gene_name)] <- res_table$gene_id[is.na(res_table$gene_name)]

    # 各サンプルのTPM値を追加
    tpm_common <- tpm_filtered[res_table$gene_id, , drop = FALSE]
    for (sample_name in colnames(tpm_common)) {
      res_table[[paste0("TPM_", sample_name)]] <- tpm_common[res_table$gene_id, sample_name]
    }

    # グループごとのmean TPMを追加
    res_table[[paste0("TPM_mean_", comp_parts[1])]] <- mean_tpm_group1[res_table$gene_id]
    res_table[[paste0("TPM_mean_", comp_parts[2])]] <- mean_tpm_group2[res_table$gene_id]

    # TPMベースのlogFCを追加
    res_table$logFC <- tpm_log2FC[res_table$gene_id]

    # edgeRからPValueとFDRのみ取得（CPMベースの統計量は除外）
    res_table$PValue <- res$table[res_table$gene_id, "PValue"]
    res_table$FDR <- res$table[res_table$gene_id, "FDR"]

    # 列の順序を整理（gene_name, gene_id, 各サンプルTPM, mean, logFC, PValue, FDR）
    sample_tpm_cols <- paste0("TPM_", colnames(tpm_common))
    core_cols <- c("gene_name", "gene_id", sample_tpm_cols,
                   paste0("TPM_mean_", comp_parts[1]),
                   paste0("TPM_mean_", comp_parts[2]),
                   "logFC", "PValue", "FDR")
    res_table <- res_table[, core_cols]

    output_prefix <- gsub("-", "_vs_", comparison)
    write.csv(res_table, file = file.path(output_dir, paste0("DEG_TPM_", output_prefix, "_all.csv")), row.names = FALSE)

    sig <- res_table[res_table$FDR < 0.05, ]
    cat("  有意差遺伝子数 (FDR<0.05):", nrow(sig), "\n")

    # TPMベースで有意な遺伝子（|logFC| > 1 & FDR < 0.05）
    sig_tpm <- res_table[res_table$FDR < 0.05 & abs(res_table$logFC) > 1, ]
    cat("  有意差遺伝子数 (|logFC|>1 & FDR<0.05):", nrow(sig_tpm), "\n\n")

    # Volcano plot (TPMベース)
    res_df <- as.data.frame(res_table)
    res_df$category <- "Others"
    res_df$category[res_df$FDR < 0.05 & res_df$logFC > 1] <- "Up"
    res_df$category[res_df$FDR < 0.05 & res_df$logFC < -1] <- "Down"

    pdf(file.path(output_dir, paste0("Volcano_plot_", output_prefix, ".pdf")), width = 8, height = 6)
    p <- ggplot(res_df, aes(x = logFC, y = -log10(FDR), color = category)) +
        geom_point(alpha = 0.5, size = 1) +
        scale_color_manual(values = c("Down" = "blue", "Others" = "grey", "Up" = "red")) +
        geom_vline(xintercept = c(-1, 1), linetype = "dashed") +
        geom_hline(yintercept = -log10(0.05), linetype = "dashed") +
        theme_minimal() +
        labs(title = paste("Volcano Plot:", comparison),
             x = "log2 Fold Change (TPM-based)",
             y = "-log10(FDR)")
    print(p)
    dev.off()

    summary_results <- rbind(summary_results, data.frame(
        Comparison = comparison, Total_Genes = nrow(res$table),
        Significant_FDR005 = nrow(sig),
        Up_regulated = nrow(sig[sig$logFC > 0, ]),
        Down_regulated = nrow(sig[sig$logFC < 0, ]),
        stringsAsFactors = FALSE))
}

write.csv(summary_results, file = file.path(output_dir, "DEG_summary.csv"), row.names = FALSE)
cat("\n解析完了\n")
cat("出力ファイル:\n")
cat("  - TPM_all_samples.csv: 全サンプルのTPM値\n")
cat("  - DEG_TPM_*_all.csv: 差次発現解析結果 (各サンプルTPM, mean, logFC, PValue, FDR)\n")
cat("  - PCA_plot_TPM.pdf: PCAプロット\n")
cat("  - Volcano_plot_*.pdf: ボルケーノプロット\n")
RSCRIPT

Rscript "$EDGER_DIR/run_edgeR.R" "$COUNTS_DIR/gene_counts.txt" "$SAMPLE_INFO" "$EDGER_DIR" "$COMPARISON" "$GTF_FILE"
echo -e "${GREEN}edgeR解析完了${NC}"

################################################################################
# 完了
################################################################################

echo ""
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}  パイプライン完了: $(date)${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""
echo -e "${GREEN}結果ディレクトリ:${NC}"
echo "  全体: $OUTPUT_DIR"
echo "  QCレポート: $MULTIQC_DIR/multiqc_report.html"
echo "  カウントデータ: $COUNTS_DIR/gene_counts.txt"
echo "  edgeR結果: $EDGER_DIR/"
echo ""
echo -e "${YELLOW}ログファイル: $LOG_FILE${NC}"
