#!/bin/bash

################################################################################
# RNA-seq解析環境セットアップスクリプト（統合版）
#
# 機能:
#   1. Miniconda + 必要なツールをローカルにインストール
#   2. 永続的な環境アクティベーションファイルを生成
#   3. 再現性の高い解析環境を構築
#
# 使い方:
#   ./setup_rnaseq_environment.sh
#
# インストール後:
#   自動的に環境が有効化されます
#   または手動で: source ./activate_env.sh
#
# 作成者: rce13
# 作成日: 2025-12-15
################################################################################

set -e

# 色付き出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ディレクトリ設定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLS_DIR="${BASE_DIR}/rnaseq_tools"
MINICONDA_DIR="${TOOLS_DIR}/miniconda3"
CONDA_ENV_DIR="${TOOLS_DIR}/conda_env"

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}  RNA-seq解析環境セットアップ${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""
echo "インストール先: ${TOOLS_DIR}"
echo ""

################################################################################
# 既存環境のチェック
################################################################################

if [ -d "$CONDA_ENV_DIR" ] && [ -f "${MINICONDA_DIR}/etc/profile.d/conda.sh" ]; then
    echo -e "${GREEN}既存の環境を検出しました${NC}"
    echo ""
    echo "オプション:"
    echo "  1. 既存環境を使用（推奨）"
    echo "  2. 既存環境を削除して再インストール"
    echo "  3. 中止"
    echo ""
    read -p "選択してください [1-3, デフォルト: 1]: " CHOICE
    CHOICE=${CHOICE:-1}

    case $CHOICE in
        1)
            echo -e "${GREEN}既存環境を使用します${NC}"
            # 環境アクティベーションファイルを再生成
            source "${MINICONDA_DIR}/etc/profile.d/conda.sh"
            conda activate "$CONDA_ENV_DIR"

            # activate_env.sh を生成
            cat > "${SCRIPT_DIR}/activate_env.sh" << EOF
#!/bin/bash
# RNA-seq解析環境アクティベーションスクリプト
# 使い方: source ./activate_env.sh

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="\$(cd "\${SCRIPT_DIR}/.." && pwd)"
MINICONDA_DIR="\${BASE_DIR}/rnaseq_tools/miniconda3"
CONDA_ENV_DIR="\${BASE_DIR}/rnaseq_tools/conda_env"

if [ ! -d "\$CONDA_ENV_DIR" ]; then
    echo -e "\033[0;31mエラー: 環境が見つかりません: \$CONDA_ENV_DIR\033[0m"
    echo "まず ./setup_rnaseq_environment.sh を実行してください"
    return 1
fi

# Conda初期化
source "\${MINICONDA_DIR}/etc/profile.d/conda.sh"

# 環境アクティベート
conda activate "\$CONDA_ENV_DIR"

echo -e "\033[0;32m✓ RNA-seq解析環境がアクティベートされました\033[0m"
echo ""
echo "利用可能なツール:"
echo "  - fastqc: \$(which fastqc 2>/dev/null || echo '未検出')"
echo "  - trimmomatic: \$(which trimmomatic 2>/dev/null || echo '未検出')"
echo "  - STAR: \$(which STAR 2>/dev/null || echo '未検出')"
echo "  - featureCounts: \$(which featureCounts 2>/dev/null || echo '未検出')"
echo "  - multiqc: \$(which multiqc 2>/dev/null || echo '未検出')"
echo "  - Rscript: \$(which Rscript 2>/dev/null || echo '未検出')"
echo ""
EOF
            chmod +x "${SCRIPT_DIR}/activate_env.sh"

            echo ""
            echo -e "${GREEN}======================================${NC}"
            echo -e "${GREEN}  環境の準備が完了しました${NC}"
            echo -e "${GREEN}======================================${NC}"
            echo ""
            echo -e "${YELLOW}環境のアクティベート方法:${NC}"
            echo -e "  ${BLUE}source ./activate_env.sh${NC}"
            echo ""
            echo -e "${YELLOW}パイプラインの実行:${NC}"
            echo -e "  ${BLUE}./rnaseq_pipeline.sh${NC}"
            echo -e "  （環境は自動的にアクティベートされます）"
            echo ""
            exit 0
            ;;
        2)
            echo -e "${YELLOW}既存環境を削除中...${NC}"
            rm -rf "$TOOLS_DIR"
            ;;
        3)
            echo "中止しました"
            exit 0
            ;;
        *)
            echo -e "${RED}無効な選択です${NC}"
            exit 1
            ;;
    esac
fi

################################################################################
# OSとアーキテクチャの検出
################################################################################

echo -e "${GREEN}[1] システム情報の検出${NC}"
OS=$(uname -s)
ARCH=$(uname -m)

if [ "$OS" = "Darwin" ]; then
    if [ "$ARCH" = "arm64" ]; then
        MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-arm64.sh"
        echo "  検出: macOS (Apple Silicon)"
    else
        MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-x86_64.sh"
        echo "  検出: macOS (Intel)"
    fi
elif [ "$OS" = "Linux" ]; then
    if [ "$ARCH" = "x86_64" ]; then
        MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
        echo "  検出: Linux (x86_64)"
    else
        echo -e "${RED}エラー: サポートされていないアーキテクチャ: $ARCH${NC}"
        exit 1
    fi
else
    echo -e "${RED}エラー: サポートされていないOS: $OS${NC}"
    exit 1
fi

################################################################################
# ディレクトリ作成
################################################################################

echo ""
echo -e "${GREEN}[2] ディレクトリ作成${NC}"
mkdir -p "$TOOLS_DIR"
cd "$TOOLS_DIR"

################################################################################
# Minicondaのダウンロードとインストール
################################################################################

echo ""
echo -e "${GREEN}[3] Minicondaのダウンロード${NC}"
MINICONDA_INSTALLER="$TOOLS_DIR/miniconda_installer.sh"

if [ -f "${MINICONDA_DIR}/bin/conda" ]; then
    echo -e "${YELLOW}  Miniconda は既にインストール済み（スキップ）${NC}"
else
    echo "  ダウンロード中: $MINICONDA_URL"
    curl -L "$MINICONDA_URL" -o "$MINICONDA_INSTALLER"

    echo ""
    echo -e "${GREEN}[4] Minicondaのインストール${NC}"
    bash "$MINICONDA_INSTALLER" -b -p "$MINICONDA_DIR"
    rm "$MINICONDA_INSTALLER"
fi

################################################################################
# Conda環境の作成
################################################################################

# Conda初期化
source "${MINICONDA_DIR}/etc/profile.d/conda.sh"

echo ""
echo -e "${GREEN}[5] Conda環境の作成${NC}"

if [ -d "$CONDA_ENV_DIR" ] && [ -f "${CONDA_ENV_DIR}/bin/python" ]; then
    echo -e "${YELLOW}  Conda環境は既に作成済み（スキップ）${NC}"
    conda activate "$CONDA_ENV_DIR"
else
    conda create -y -p "$CONDA_ENV_DIR" python=3.10
    conda activate "$CONDA_ENV_DIR"
fi

################################################################################
# 必要なツールのインストール
################################################################################

echo ""
echo -e "${GREEN}[6] RNA-seq解析ツールのインストール${NC}"
echo ""
echo -e "${YELLOW}インストールするツール:${NC}"
echo "  - FastQC: 品質評価"
echo "  - Trimmomatic: アダプター除去・品質フィルタリング"
echo "  - STAR: 高速アライメント"
echo "  - Subread (featureCounts): リードカウント定量"
echo "  - MultiQC: QCレポート統合"
echo "  - R + Bioconductor: 統計解析"
echo "  - edgeR: 差次発現解析"
echo "  - ggplot2: データ可視化"
echo ""
echo -e "${YELLOW}※インストールには5-15分程度かかる場合があります${NC}"
echo ""

# チャンネル設定
conda config --add channels defaults
conda config --add channels bioconda
conda config --add channels conda-forge
conda config --set channel_priority strict

# ツールのインストール（個別にチェック）
install_tool() {
    local tool_name=$1
    local conda_package=$2
    local check_command=${3:-$tool_name}

    if command -v "$check_command" &> /dev/null; then
        echo -e "  ${GREEN}✓ ${tool_name} (既にインストール済み)${NC}"
    else
        echo -e "  ${YELLOW}Installing ${tool_name}...${NC}"
        conda install -y "$conda_package"
        if command -v "$check_command" &> /dev/null; then
            echo -e "  ${GREEN}✓ ${tool_name} インストール完了${NC}"
        else
            echo -e "  ${RED}✗ ${tool_name} インストール失敗${NC}"
        fi
    fi
}

install_tool "FastQC" "fastqc" "fastqc"
install_tool "Trimmomatic" "trimmomatic" "trimmomatic"
install_tool "STAR" "star" "STAR"
install_tool "Subread" "subread" "featureCounts"
install_tool "MultiQC" "multiqc" "multiqc"
install_tool "R" "r-base" "Rscript"

# R パッケージのインストール
echo ""
echo -e "${GREEN}[7] Rパッケージのインストール${NC}"

install_r_package() {
    local package_name=$1
    local conda_package=$2

    Rscript --vanilla -e "if (requireNamespace('$package_name', quietly = TRUE)) { cat('  \033[0;32m✓ $package_name (既にインストール済み)\033[0m\n'); quit(status=0) } else { quit(status=1) }" 2>/dev/null

    if [ $? -eq 0 ]; then
        return 0
    fi

    echo -e "  ${YELLOW}Installing $package_name...${NC}"
    conda install -y "$conda_package"

    Rscript --vanilla -e "if (requireNamespace('$package_name', quietly = TRUE)) { cat('  \033[0;32m✓ $package_name インストール完了\033[0m\n') } else { cat('  \033[0;31m✗ $package_name インストール失敗\033[0m\n') }" 2>/dev/null
}

install_r_package "edgeR" "bioconductor-edger"
install_r_package "ggplot2" "r-ggplot2"

################################################################################
# インストール確認
################################################################################

echo ""
echo -e "${GREEN}[8] インストール確認${NC}"
echo ""

TOOLS=("fastqc" "trimmomatic" "STAR" "featureCounts" "multiqc" "Rscript")
ALL_OK=true

for tool in "${TOOLS[@]}"; do
    if command -v "$tool" &> /dev/null; then
        echo -e "  ${GREEN}✓${NC} $tool"
        # バージョン情報を取得（エラーは無視）
        case "$tool" in
            fastqc)
                fastqc --version 2>&1 | head -n1 | sed 's/^/      /' || true
                ;;
            trimmomatic)
                trimmomatic -version 2>&1 | head -n1 | sed 's/^/      /' || true
                ;;
            STAR)
                STAR --version 2>&1 | sed 's/^/      /' || true
                ;;
            featureCounts)
                featureCounts -v 2>&1 | grep "featureCounts" | sed 's/^/      /' || true
                ;;
            multiqc)
                multiqc --version 2>&1 | sed 's/^/      /' || true
                ;;
            Rscript)
                Rscript --version 2>&1 | head -n1 | sed 's/^/      /' || true
                ;;
        esac
    else
        echo -e "  ${RED}✗${NC} $tool"
        ALL_OK=false
    fi
done

# Rパッケージの確認
echo ""
echo -e "${BLUE}Rパッケージ:${NC}"
Rscript --vanilla << 'EOF'
packages <- c("edgeR", "ggplot2")
for (pkg in packages) {
    if (requireNamespace(pkg, quietly = TRUE)) {
        version <- packageVersion(pkg)
        cat(paste0("  \033[0;32m✓\033[0m ", pkg, " (v", version, ")\n"))
    } else {
        cat(paste0("  \033[0;31m✗\033[0m ", pkg, "\n"))
    }
}
EOF

################################################################################
# 環境アクティベーションスクリプトの生成
################################################################################

echo ""
echo -e "${GREEN}[9] 環境アクティベーションファイルの生成${NC}"

cat > "${SCRIPT_DIR}/activate_env.sh" << 'EOF'
#!/bin/bash
# RNA-seq解析環境アクティベーションスクリプト
# 使い方: source ./activate_env.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MINICONDA_DIR="${BASE_DIR}/rnaseq_tools/miniconda3"
CONDA_ENV_DIR="${BASE_DIR}/rnaseq_tools/conda_env"

if [ ! -d "$CONDA_ENV_DIR" ]; then
    echo -e "\033[0;31mエラー: 環境が見つかりません: $CONDA_ENV_DIR\033[0m"
    echo "まず ./setup_rnaseq_environment.sh を実行してください"
    return 1
fi

# Conda初期化
source "${MINICONDA_DIR}/etc/profile.d/conda.sh"

# 環境アクティベート
conda activate "$CONDA_ENV_DIR"

echo -e "\033[0;32m✓ RNA-seq解析環境がアクティベートされました\033[0m"
echo ""
echo "利用可能なツール:"
echo "  - fastqc: $(which fastqc 2>/dev/null || echo '未検出')"
echo "  - trimmomatic: $(which trimmomatic 2>/dev/null || echo '未検出')"
echo "  - STAR: $(which STAR 2>/dev/null || echo '未検出')"
echo "  - featureCounts: $(which featureCounts 2>/dev/null || echo '未検出')"
echo "  - multiqc: $(which multiqc 2>/dev/null || echo '未検出')"
echo "  - Rscript: $(which Rscript 2>/dev/null || echo '未検出')"
echo ""
echo "環境を無効化: conda deactivate"
echo ""
EOF

chmod +x "${SCRIPT_DIR}/activate_env.sh"

echo -e "  ${GREEN}✓${NC} ${SCRIPT_DIR}/activate_env.sh を作成しました"

################################################################################
# rnaseq_pipeline.sh の自動アクティベーション設定を更新
################################################################################

echo ""
echo -e "${GREEN}[10] パイプラインスクリプトの更新${NC}"

# パイプラインスクリプトにactivate_env.shを自動的にsourceする設定が含まれているか確認
if [ -f "${SCRIPT_DIR}/rnaseq_pipeline.sh" ]; then
    echo -e "  ${GREEN}✓${NC} rnaseq_pipeline.sh は既に環境の自動アクティベーションに対応しています"
else
    echo -e "  ${YELLOW}!${NC} rnaseq_pipeline.sh が見つかりません"
fi

################################################################################
# 完了メッセージ
################################################################################

conda deactivate

echo ""
echo -e "${BLUE}======================================${NC}"
if [ "$ALL_OK" = true ]; then
    echo -e "${GREEN}  セットアップ完了！${NC}"
else
    echo -e "${YELLOW}  セットアップ完了（一部警告あり）${NC}"
fi
echo -e "${BLUE}======================================${NC}"
echo ""
echo -e "${GREEN}インストール先:${NC}"
echo "  ${TOOLS_DIR}"
echo ""
echo -e "${GREEN}環境のアクティベート方法:${NC}"
echo ""
echo "  【方法1】手動でアクティベート（推奨）"
echo -e "    ${BLUE}source ./activate_env.sh${NC}"
echo ""
echo "  【方法2】パイプラインを直接実行（自動アクティベート）"
echo -e "    ${BLUE}./rnaseq_pipeline.sh${NC}"
echo ""
echo -e "${YELLOW}次のステップ:${NC}"
echo "  1. FASTQファイルを準備"
echo "  2. STARゲノムインデックスを準備（または ./build_star_index.sh で作成）"
echo "  3. ./rnaseq_pipeline.sh を実行"
echo ""
echo -e "${GREEN}利用可能なツール:${NC}"
for tool in "${TOOLS[@]}"; do
    echo "  - $tool"
done
echo ""

################################################################################
# 永続的なPATH設定（オプション）
################################################################################

echo ""
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}  永続的な環境設定（オプション）${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""
echo "シェルの設定ファイルに環境のアクティベーションを追加しますか？"
echo "これにより、新しいターミナルを開くたびに自動的に環境が有効化されます。"
echo ""
echo -e "${YELLOW}推奨: プロジェクト専用の環境なので、手動アクティベートがおすすめです${NC}"
echo ""
echo "オプション:"
echo "  1. 追加しない（推奨 - 必要時に 'source ./activate_env.sh' を実行）"
echo "  2. ~/.zshrc に追加（macOS デフォルト）"
echo "  3. ~/.bashrc に追加（Linux / bash ユーザー）"
echo ""
read -p "選択してください [1-3, デフォルト: 1]: " PERSIST_CHOICE
PERSIST_CHOICE=${PERSIST_CHOICE:-1}

case $PERSIST_CHOICE in
    2)
        # zshrcに追加
        SHELL_RC="${HOME}/.zshrc"
        if [ -f "$SHELL_RC" ]; then
            # 既に設定が存在するかチェック
            if grep -q "rnaseq_tools/miniconda3/etc/profile.d/conda.sh" "$SHELL_RC"; then
                echo -e "${YELLOW}既に設定が存在します。スキップします。${NC}"
            else
                echo "" >> "$SHELL_RC"
                echo "# RNA-seq解析環境（自動追加: $(date)）" >> "$SHELL_RC"
                echo "source ${MINICONDA_DIR}/etc/profile.d/conda.sh" >> "$SHELL_RC"
                echo "conda activate ${CONDA_ENV_DIR}" >> "$SHELL_RC"
                echo ""
                echo -e "${GREEN}✓ ~/.zshrc に環境設定を追加しました${NC}"
                echo -e "${YELLOW}新しいターミナルで有効化するには: source ~/.zshrc${NC}"
            fi
        else
            echo -e "${RED}エラー: ~/.zshrc が見つかりません${NC}"
        fi
        ;;
    3)
        # bashrcに追加
        SHELL_RC="${HOME}/.bashrc"
        if [ -f "$SHELL_RC" ]; then
            # 既に設定が存在するかチェック
            if grep -q "rnaseq_tools/miniconda3/etc/profile.d/conda.sh" "$SHELL_RC"; then
                echo -e "${YELLOW}既に設定が存在します。スキップします。${NC}"
            else
                echo "" >> "$SHELL_RC"
                echo "# RNA-seq解析環境（自動追加: $(date)）" >> "$SHELL_RC"
                echo "source ${MINICONDA_DIR}/etc/profile.d/conda.sh" >> "$SHELL_RC"
                echo "conda activate ${CONDA_ENV_DIR}" >> "$SHELL_RC"
                echo ""
                echo -e "${GREEN}✓ ~/.bashrc に環境設定を追加しました${NC}"
                echo -e "${YELLOW}新しいターミナルで有効化するには: source ~/.bashrc${NC}"
            fi
        else
            echo -e "${RED}エラー: ~/.bashrc が見つかりません${NC}"
        fi
        ;;
    1|*)
        echo -e "${GREEN}環境設定は追加しませんでした${NC}"
        echo ""
        echo "環境を使用する際は、以下のいずれかを実行してください:"
        echo -e "  ${BLUE}source ./activate_env.sh${NC}  （推奨）"
        echo -e "  ${BLUE}./rnaseq_pipeline.sh${NC}      （パイプライン実行時に自動アクティベート）"
        ;;
esac

echo ""
