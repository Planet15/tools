#!/bin/bash

# Oracle Linux SRPM 다운로드 및 빌드 스크립트
# 사용법
#   1) 상세 버전 입력: ./download_and_build_srpm.sh kexec-tools-2.0.4-32.0.2.el7.x86_64.rpm
#   2) 패키지명만 입력: ./download_and_build_srpm.sh kexec-tools
#   3) changelog 검색: ./download_and_build_srpm.sh kexec-tools --changelog CVE
#   4) 캐시 무시: ./download_and_build_srpm.sh kexec-tools --no-cache
#   5) changelog만 검색: ./download_and_build_srpm.sh kexec-tools --changelog CVE --changelog-only

PACKAGE_FILE=""
CHANGELOG_TERM=""
NO_CACHE="off"
CHANGELOG_ONLY="off"

print_usage() {
    echo "사용법: $0 <패키지파일명|패키지명> [옵션]"
    echo ""
    echo "옵션:"
    echo "  -c, --changelog <검색어>   SPEC의 %changelog 섹션에서 검색"
    echo "      --changelog-only       changelog 검색만 하고 종료 (--changelog 필요)"
    echo "      --no-cache             기존 src.rpm 재사용 없이 항상 새로 다운로드"
    echo "  -h, --help                 전체 도움말 출력"
    echo "  -H, --help-short           짧은 도움말 출력"
    echo ""
    echo "캐시:"
    echo "  기본 캐시 경로: ~/.cache/download_and_build_srpm"
    echo "  변경: SRPM_CACHE_DIR=/path/to/cache 환경변수 사용"
    echo ""
    echo "예시:"
    echo "  $0 kexec-tools-2.0.4-32.0.2.el7.x86_64.rpm"
    echo "  $0 kexec-tools"
    echo "  $0 kexec-tools --changelog cve"
    echo "  $0 kexec-tools --changelog cve --changelog-only"
    echo "  $0 kexec-tools --no-cache"
    echo "  OL_VERSION_OVERRIDE=7 $0 kexec-tools --changelog fix"
    echo "  SRPM_CACHE_DIR=/var/tmp/srpm-cache $0 kexec-tools"
}

print_usage_short() {
    echo "사용법: $0 <패키지파일명|패키지명> [-c <검색어>] [--changelog-only] [--no-cache] [--help|-h] [--help-short|-H]"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --changelog|-c)
            shift
            if [ -z "${1:-}" ]; then
                echo "오류: --changelog 옵션에는 검색어가 필요합니다."
                print_usage
                exit 1
            fi
            CHANGELOG_TERM="$1"
            ;;
        --no-cache)
            NO_CACHE="on"
            ;;
        --changelog-only)
            CHANGELOG_ONLY="on"
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        --help-short|-H)
            print_usage_short
            exit 0
            ;;
        -*)
            echo "오류: 알 수 없는 옵션입니다. $1"
            print_usage
            exit 1
            ;;
        *)
            if [ -n "$PACKAGE_FILE" ]; then
                echo "오류: 패키지 인자는 하나만 지정할 수 있습니다."
                print_usage
                exit 1
            fi
            PACKAGE_FILE="$1"
            ;;
    esac
    shift
done

if [ -z "$PACKAGE_FILE" ]; then
    print_usage
    exit 1
fi

if [ "$CHANGELOG_ONLY" = "on" ] && [ -z "$CHANGELOG_TERM" ]; then
    echo "오류: --changelog-only는 --changelog <검색어>와 함께 사용해야 합니다."
    print_usage
    exit 1
fi

# 입력 정리 (.src.rpm/.rpm 제거 + 아키텍처 접미사 제거)
NORMALIZED_INPUT="${PACKAGE_FILE%.src.rpm}"
NORMALIZED_INPUT="${NORMALIZED_INPUT%.rpm}"
NORMALIZED_INPUT=$(echo "$NORMALIZED_INPUT" | sed -E 's/\.(x86_64|aarch64|noarch|i686|i386|ppc64le|s390x)$//')

PACKAGE_NAME=""
PACKAGE_BASENAME=""
EL_VERSION=""
HOST_EL_VERSION=""
COMPAT_MODE="off"
RPMBUILD_COMPAT_DEFINES=()

# 상세 버전 포함 입력
if [[ $NORMALIZED_INPUT =~ el([0-9]+) ]]; then
    EL_VERSION="${BASH_REMATCH[1]}"
    PACKAGE_NAME="$NORMALIZED_INPUT"
    PACKAGE_BASENAME=$(echo "$PACKAGE_NAME" | sed -E 's/^([a-z0-9_.+-]+)-[0-9].*/\1/')
else
    # 패키지명만 입력
    PACKAGE_BASENAME="$NORMALIZED_INPUT"

    if [ -n "${OL_VERSION_OVERRIDE:-}" ]; then
        EL_VERSION="$OL_VERSION_OVERRIDE"
    elif [ -r /etc/os-release ]; then
        HOST_VERSION_ID=$(grep '^VERSION_ID=' /etc/os-release | head -1 | cut -d'=' -f2 | tr -d '"')
        EL_VERSION=$(echo "$HOST_VERSION_ID" | cut -d'.' -f1)
    fi

    if [ -z "$EL_VERSION" ]; then
        echo "오류: 패키지명만 입력한 경우 EL 버전을 결정할 수 없습니다."
        echo "다음 중 하나를 사용하세요:"
        echo "  1) 상세 버전 입력 (예: kexec-tools-2.0.4-32.0.2.el7.x86_64.rpm)"
        echo "  2) 환경변수 지정 (예: OL_VERSION_OVERRIDE=7 $0 kexec-tools)"
        exit 1
    fi
fi

# 호스트 EL 버전 추출
if [ -r /etc/os-release ]; then
    HOST_VERSION_ID=$(grep '^VERSION_ID=' /etc/os-release | head -1 | cut -d'=' -f2 | tr -d '"')
    HOST_EL_VERSION=$(echo "$HOST_VERSION_ID" | cut -d'.' -f1)
fi

# OL10 이상 호스트에서 EL5/6/7 대상 빌드 시 호환 모드 활성화
if [[ "$HOST_EL_VERSION" =~ ^[0-9]+$ ]] && [[ "$EL_VERSION" =~ ^[0-9]+$ ]]; then
    if [ "$HOST_EL_VERSION" -ge 10 ] && [ "$EL_VERSION" -le 7 ]; then
        COMPAT_MODE="on"
        RPMBUILD_COMPAT_DEFINES=(
            --define "_build_id_links none"
            --define "_source_filedigest_algorithm 1"
            --define "_binary_filedigest_algorithm 1"
            --define "_default_patch_fuzz 2"
        )
    fi
fi

# Oracle Linux 버전별 URL 매핑
case $EL_VERSION in
    5)
        BASE_URL="https://oss.oracle.com/ol5/SRPMS-updates/"
        OS_VERSION="ol5"
        ;;
    6)
        BASE_URL="https://oss.oracle.com/ol6/SRPMS-updates/"
        OS_VERSION="ol6"
        ;;
    7)
        BASE_URL="https://oss.oracle.com/ol7/SRPMS-updates/"
        OS_VERSION="ol7"
        ;;
    8)
        BASE_URL="https://oss.oracle.com/ol8/SRPMS-updates/"
        OS_VERSION="ol8"
        ;;
    9)
        BASE_URL="https://oss.oracle.com/ol9/SRPMS-updates/"
        OS_VERSION="ol9"
        ;;
    10)
        BASE_URL="https://oss.oracle.com/ol10/SRPMS-updates/"
        OS_VERSION="ol10"
        ;;
    *)
        echo "오류: 지원하지 않는 Oracle Linux 버전입니다. (el$EL_VERSION)"
        exit 1
        ;;
esac

SEARCH_INDEX_PAGES=()
if [ "$EL_VERSION" = "5" ] && [[ "$PACKAGE_BASENAME" == kernel-uek* ]]; then
    SEARCH_INDEX_PAGES=(
        "https://yum.oracle.com/repo/OracleLinux/OL5/UEK/latest/x86_64/index_src.html"
    )
elif [ "$EL_VERSION" = "6" ] && [[ "$PACKAGE_BASENAME" == kernel-uek* ]]; then
    SEARCH_INDEX_PAGES=(
        "https://yum.oracle.com/repo/OracleLinux/OL6/UEKR4/x86_64/index_src.html"
        "https://yum.oracle.com/repo/OracleLinux/OL6/UEKR3/latest/x86_64/index_src.html"
        "https://yum.oracle.com/repo/OracleLinux/OL6/UEK/latest/x86_64/index_src.html"
    )
elif [ "$EL_VERSION" = "7" ] && [[ "$PACKAGE_BASENAME" == kernel-uek* ]]; then
    SEARCH_INDEX_PAGES=(
        "https://yum.oracle.com/repo/OracleLinux/OL7/UEKR6/x86_64/index_src.html"
        "https://yum.oracle.com/repo/OracleLinux/OL7/UEKR5/x86_64/index_src.html"
        "https://yum.oracle.com/repo/OracleLinux/OL7/UEKR4/x86_64/index_src.html"
    )
elif [ "$EL_VERSION" = "8" ] && [[ "$PACKAGE_BASENAME" == kernel-uek* ]]; then
    SEARCH_INDEX_PAGES=(
        "https://yum.oracle.com/repo/OracleLinux/OL8/UEKR7/x86_64/index_src.html"
        "https://yum.oracle.com/repo/OracleLinux/OL8/UEKR6/x86_64/index_src.html"
    )
elif [ "$EL_VERSION" = "9" ] && [[ "$PACKAGE_BASENAME" == kernel-uek* ]]; then
    SEARCH_INDEX_PAGES=(
        "https://yum.oracle.com/repo/OracleLinux/OL9/UEKR8/x86_64/index_src.html"
        "https://yum.oracle.com/repo/OracleLinux/OL9/UEKR7/x86_64/index_src.html"
    )
elif [ "$EL_VERSION" = "10" ] && [[ "$PACKAGE_BASENAME" == kernel-uek* ]]; then
    SEARCH_INDEX_PAGES=(
        "https://yum.oracle.com/repo/OracleLinux/OL10/UEKR8/x86_64/index_src.html"
    )
fi

echo "======================================"
echo "Oracle Linux $EL_VERSION SRPM 다운로드 및 빌드"
echo "======================================"
if [ -n "$PACKAGE_NAME" ]; then
    echo "입력 방식: 상세 버전"
    echo "패키지명: $PACKAGE_NAME"
else
    echo "입력 방식: 패키지명만"
    echo "패키지명: $PACKAGE_BASENAME (최신 버전 자동 선택)"
fi
echo "EL 버전: el$EL_VERSION"
if [ -n "$HOST_EL_VERSION" ]; then
    echo "호스트 버전: el$HOST_EL_VERSION"
fi
echo "호환 모드: $COMPAT_MODE"
echo "기본 URL: $BASE_URL"
echo ""

echo "패키지 기본명: $PACKAGE_BASENAME"

# SRPM 파일명/URL 초기값 생성
SRPM_FILE=""
SRPM_URL=""

if [ -n "$PACKAGE_NAME" ]; then
    SRPM_FILE="${PACKAGE_NAME}.src.rpm"
    SRPM_URL="${BASE_URL}${SRPM_FILE}"
    echo "SRPM 파일명: $SRPM_FILE"
    echo "다운로드 URL: $SRPM_URL"
else
    echo "SRPM 파일명: (자동 선택 예정)"
    echo "다운로드 URL: (자동 선택 예정)"
fi
echo ""

escape_regex() {
    printf '%s' "$1" | sed -e 's/[][(){}.^$*+?|\\/]/\\&/g'
}

find_latest_exact_srpm_in_html() {
    local html="$1"
    local pkg_name="$2"
    local escaped_pkg_name

    escaped_pkg_name=$(escape_regex "$pkg_name")

    echo "$html" \
        | grep -oP "href=['\"]?\K[^'\" ]*\.src\.rpm" \
        | grep -E "^${escaped_pkg_name}-[0-9][^/]*\.src\.rpm$" \
        | sort -V \
        | tail -1
}

extract_srpm_hrefs_from_html() {
    local html="$1"

    echo "$html" | grep -oP "href=['\"]?\K[^'\" >]*\.src\.rpm"
}

resolve_href_url() {
    local page_url="$1"
    local href="$2"
    local page_dir

    if [[ "$href" =~ ^https?:// ]]; then
        echo "$href"
        return 0
    fi

    page_dir="${page_url%/*}/"
    echo "${page_dir}${href}"
}

find_exact_srpm_href_in_html() {
    local html="$1"
    local srpm_filename="$2"

    extract_srpm_hrefs_from_html "$html" | while read -r href; do
        [ -n "$href" ] || continue
        if [ "$(basename "$href")" = "$srpm_filename" ]; then
            echo "$href"
            break
        fi
    done
}

find_latest_exact_srpm_href_in_html() {
    local html="$1"
    local pkg_name="$2"
    local escaped_pkg_name

    escaped_pkg_name=$(escape_regex "$pkg_name")

    extract_srpm_hrefs_from_html "$html" \
        | while read -r href; do
            local base
            [ -n "$href" ] || continue
            base=$(basename "$href")
            printf '%s\t%s\n' "$base" "$href"
        done \
        | grep -E "^${escaped_pkg_name}-[0-9][^/]*\.src\.rpm[[:space:]]" \
        | sort -t $'\t' -k1,1V \
        | tail -1 \
        | cut -f2-
}

# 함수: 디렉터리에서 SRPM 파일 검색
search_srpm_in_directory() {
    local search_url="$1"
    local pkg_name="$2"
    local depth="$3"
    local escaped_pkg_name

    if [ "$depth" -gt 5 ]; then
        echo "최대 깊이 도달 (5단계)" >&2
        return 1
    fi

    echo "  검색 중: $search_url (깊이: $depth)" >&2

    local html
    html=$(wget -q -O - "$search_url" 2>/dev/null)

    if [ -z "$html" ]; then
        echo "  오류: 페이지 접근 불가" >&2
        return 1
    fi

    escaped_pkg_name=$(escape_regex "$pkg_name")
    local srpm_filename
    srpm_filename=$(echo "$html" | grep -oP "href=['\"]?\K[^'\" ]*\.src\.rpm" | grep -E "^${escaped_pkg_name}(\.src\.rpm|-.*\.src\.rpm)$" | head -1)

    if [ -n "$srpm_filename" ]; then
        echo "  발견: $srpm_filename" >&2
        echo "${search_url}${srpm_filename}"
        return 0
    fi

    local subdirs
    subdirs=$(echo "$html" | grep -oP "href=['\"]?\K[a-zA-Z0-9._-]+/" | grep -i "srpm\|archive\|release\|updates\|stable" | sort -u)

    if [ -n "$subdirs" ]; then
        for subdir in $subdirs; do
            local new_url="${search_url}${subdir}"
            local nested_result
            nested_result=$(search_srpm_in_directory "$new_url" "$pkg_name" $((depth + 1)))
            if [ -n "$nested_result" ]; then
                echo "$nested_result"
                return 0
            fi
        done
    fi

    return 1
}

extract_source_archive() {
    local source_dir="$1"
    local build_dir="$2"
    local package_basename="$3"
    local extract_dir="$build_dir/${package_basename}-source-extracted"
    local archive=""

    mkdir -p "$extract_dir"

    for candidate in \
        "$source_dir/${package_basename}"*.tar.gz \
        "$source_dir/${package_basename}"*.tgz \
        "$source_dir/${package_basename}"*.tar.bz2 \
        "$source_dir/${package_basename}"*.tar.xz \
        "$source_dir/${package_basename}"*.tar.zst \
        "$source_dir/${package_basename}"*.zip \
        "$source_dir/${package_basename}"*.tar; do
        if [ -f "$candidate" ]; then
            archive="$candidate"
            break
        fi
    done

    if [ -z "$archive" ]; then
        for candidate in \
            "$source_dir"/*.tar.gz \
            "$source_dir"/*.tgz \
            "$source_dir"/*.tar.bz2 \
            "$source_dir"/*.tar.xz \
            "$source_dir"/*.tar.zst \
            "$source_dir"/*.zip \
            "$source_dir"/*.tar; do
            if [ -f "$candidate" ]; then
                archive="$candidate"
                break
            fi
        done
    fi

    if [ -z "$archive" ]; then
        echo "경고: SOURCES 디렉터리에서 압축 소스 파일을 찾지 못했습니다."
        return 1
    fi

    echo "소스 아카이브 직접 추출: $archive"

    case "$archive" in
        *.tar.gz|*.tgz)
            tar -xzf "$archive" -C "$extract_dir"
            ;;
        *.tar.bz2)
            tar -xjf "$archive" -C "$extract_dir"
            ;;
        *.tar.xz)
            tar -xJf "$archive" -C "$extract_dir"
            ;;
        *.tar.zst)
            tar --zstd -xf "$archive" -C "$extract_dir"
            ;;
        *.tar)
            tar -xf "$archive" -C "$extract_dir"
            ;;
        *.zip)
            if ! command -v unzip >/dev/null 2>&1; then
                echo "경고: unzip 명령이 없어 zip 소스를 추출할 수 없습니다."
                return 1
            fi
            unzip -q "$archive" -d "$extract_dir"
            ;;
        *)
            echo "경고: 지원하지 않는 소스 아카이브 형식입니다. $archive"
            return 1
            ;;
    esac

    echo "소스 코드 직접 추출 완료: $extract_dir"
    return 0
}

search_spec_changelog() {
    local spec_file="$1"
    local search_term="$2"

    echo ""
    echo "단계 3-1: SPEC changelog 검색 중..."
    echo "검색어: $search_term"

    if [ ! -f "$spec_file" ]; then
        echo "경고: SPEC 파일이 없어 changelog 검색을 건너뜁니다. $spec_file"
        return 1
    fi

    if ! grep -q '^%changelog' "$spec_file"; then
        echo "경고: %changelog 섹션이 없습니다: $spec_file"
        return 1
    fi

    if sed -n '/^%changelog/,$p' "$spec_file" | awk -v keyword="$search_term" '
        BEGIN {
            kw = tolower(keyword)
            found = 0
            current_release = "(릴리스 정보 없음)"
            current_header = ""
            last_print_key = ""
            hl_start = sprintf("%c[1;33m", 27)
            hl_end = sprintf("%c[0m", 27)
            rel_start = sprintf("%c[1;36m", 27)
            rel_end = sprintf("%c[0m", 27)
        }

        function highlight(src, kw_raw,    out, src_low, kw_low, pos, abs_pos, start_idx, kw_len) {
            out = ""
            src_low = tolower(src)
            kw_low = tolower(kw_raw)
            start_idx = 1
            kw_len = length(kw_raw)

            if (kw_len == 0) {
                return src
            }

            while ((pos = index(substr(src_low, start_idx), kw_low)) > 0) {
                abs_pos = start_idx + pos - 1
                out = out substr(src, start_idx, abs_pos - start_idx) hl_start substr(src, abs_pos, kw_len) hl_end
                start_idx = abs_pos + kw_len
            }

            return out substr(src, start_idx)
        }

        {
            if ($0 ~ /^\*/) {
                current_header = $0
                split($0, parts, " - ")
                if (length(parts) >= 2) {
                    current_release = parts[length(parts)]
                }
            }

            line_low = tolower($0)
            if (index(line_low, kw) > 0) {
                print_key = current_release "|" current_header
                if (print_key != last_print_key) {
                    printf "릴리스: %s%s%s\n", rel_start, current_release, rel_end
                    if (current_header != "") {
                        printf "헤더: %s\n", current_header
                    }
                    last_print_key = print_key
                }

                printf "  %s\n\n", highlight($0, keyword)
                found = 1
            }
        }

        END {
            if (!found) {
                exit 1
            }
        }
    '; then
        echo "changelog 검색 결과"
        return 0
    fi

    echo "검색어 '$search_term'에 대한 changelog 결과가 없습니다."
    return 1
}

# SRPM 파일 다운로드 시도
echo "SRPM 파일 검색 중..."
SRPM_URL=""

# 상세 버전 입력: 정확한 파일 우선
if [ -n "$PACKAGE_NAME" ] && wget --spider -q "$BASE_URL${PACKAGE_NAME}.src.rpm" 2>/dev/null; then
    SRPM_FILE="${PACKAGE_NAME}.src.rpm"
    SRPM_URL="${BASE_URL}${SRPM_FILE}"
    echo "기본 위치에서 발견: $SRPM_URL"

# 상세 버전 입력: UEK on OL8 source index fallback
elif [ -n "$PACKAGE_NAME" ] && [ "${#SEARCH_INDEX_PAGES[@]}" -gt 0 ]; then
    for search_page in "${SEARCH_INDEX_PAGES[@]}"; do
        page_html=$(wget -q -O - "$search_page" 2>/dev/null)
        href_match=$(find_exact_srpm_href_in_html "$page_html" "${PACKAGE_NAME}.src.rpm")
        if [ -n "$href_match" ]; then
            SRPM_URL=$(resolve_href_url "$search_page" "$href_match")
            SRPM_FILE=$(basename "$href_match")
            echo "추가 저장소에서 발견: $SRPM_URL"
            break
        fi
    done

# 패키지명만 입력: 기본 저장소에서 최신 버전 자동 선택
elif [ -z "$PACKAGE_NAME" ]; then
    base_html=$(wget -q -O - "$BASE_URL" 2>/dev/null)
    latest_srpm=$(find_latest_exact_srpm_in_html "$base_html" "$PACKAGE_BASENAME")

    if [ -n "$latest_srpm" ]; then
        SRPM_FILE="$latest_srpm"
        SRPM_URL="${BASE_URL}${SRPM_FILE}"
        echo "최신 버전 자동 선택: $SRPM_FILE"
    elif [ "${#SEARCH_INDEX_PAGES[@]}" -gt 0 ]; then
        for search_page in "${SEARCH_INDEX_PAGES[@]}"; do
            page_html=$(wget -q -O - "$search_page" 2>/dev/null)
            href_match=$(find_latest_exact_srpm_href_in_html "$page_html" "$PACKAGE_BASENAME")
            if [ -n "$href_match" ]; then
                SRPM_URL=$(resolve_href_url "$search_page" "$href_match")
                SRPM_FILE=$(basename "$href_match")
                echo "추가 저장소에서 최신 버전 자동 선택: $SRPM_FILE"
                break
            fi
        done
    fi

    if [ -n "$SRPM_URL" ]; then
        :
    else
        echo "기본 위치에서 최신 버전을 찾지 못함. 상위 디렉터리 탐색 중..."

        PARENT_BASE=$(echo "$BASE_URL" | sed -E 's|SRPMS-updates/?$||')
        search_result=$(search_srpm_in_directory "$PARENT_BASE" "$PACKAGE_BASENAME" 0)

        if [ -n "$search_result" ]; then
            SRPM_URL="$search_result"
            SRPM_FILE=$(basename "$SRPM_URL")
            echo "탐색으로 발견: $SRPM_URL"
        else
            echo "warning: SRPM 파일을 찾을 수 없습니다"
            echo "수동으로 다음 위치를 확인하세요"
            echo "  - $BASE_URL"
            echo "  - ${PARENT_BASE}"
        fi
    fi
else
    echo "기본 위치에서 찾지 못함. 상위 디렉터리 탐색 중..."

    PARENT_BASE=$(echo "$BASE_URL" | sed -E 's|SRPMS-updates/?$||')
    search_result=$(search_srpm_in_directory "$PARENT_BASE" "$PACKAGE_NAME" 0)

    if [ -n "$search_result" ]; then
        SRPM_URL="$search_result"
        SRPM_FILE=$(basename "$SRPM_URL")
        echo "탐색으로 발견: $SRPM_URL"
    else
        echo "warning: SRPM 파일을 찾을 수 없습니다"
        echo "수동으로 다음 위치를 확인하세요"
        echo "  - $BASE_URL"
        echo "  - ${PARENT_BASE}"
    fi
fi

echo ""

# 시작 디렉터리 저장
START_DIR=$(pwd)
CACHE_DIR="${SRPM_CACHE_DIR:-$HOME/.cache/download_and_build_srpm}"
mkdir -p "$CACHE_DIR"

# 작업 디렉터리 생성
WORK_DIR=$(mktemp -d)
echo "작업 디렉터리: $WORK_DIR"
cd "$WORK_DIR" || exit 1

# rpmbuild 환경 확인 및 설치
echo ""
echo "단계 0: rpmbuild 환경 확인..."
if ! command -v rpmbuild &> /dev/null; then
    echo "rpmbuild를 찾을 수 없습니다."
    echo ""
    echo "======================================"
    echo "다음 명령으로 rpmbuild 환경을 설치하세요"
    echo "======================================"
    echo ""
    echo "# RHEL/CentOS/Oracle Linux 공통:"
    echo "sudo yum install -y rpm-build redhat-rpm-config gcc make"
    echo ""
    echo "# 또는 최소 버전:"
    echo "sudo yum install -y rpm-build"
    echo ""
    echo "# 추가 빌드 도구가 필요한 경우:"
    echo "sudo yum install -y rpm-build gcc gcc-c++ make autoconf automake libtool"
    echo ""
    echo "# dnf 사용 시스템 (Oracle Linux 8+, RHEL 8+):"
    echo "sudo dnf install -y rpm-build redhat-rpm-config gcc make"
    echo ""
    echo "======================================"
    echo "자동 설치를 시도하시겠습니까? (y/n)"
    read -r -p "선택: " auto_install

    if [ "$auto_install" = "y" ] || [ "$auto_install" = "Y" ]; then
        echo "rpmbuild 설치 중..."
        if command -v dnf &> /dev/null; then
            sudo dnf install -y rpm-build redhat-rpm-config gcc make
        elif command -v yum &> /dev/null; then
            sudo yum install -y rpm-build redhat-rpm-config gcc make
        else
            echo "오류: yum 또는 dnf를 찾을 수 없습니다"
            cd /
            rm -rf "$WORK_DIR"
            exit 1
        fi

        if ! command -v rpmbuild &> /dev/null; then
            echo "오류: rpmbuild 설치 실패"
            cd /
            rm -rf "$WORK_DIR"
            exit 1
        fi
        echo "rpmbuild 설치 완료"
    else
        echo "rpmbuild 설치가 필요합니다. 스크립트를 중단합니다."
        cd /
        rm -rf "$WORK_DIR"
        exit 1
    fi
else
    echo "rpmbuild 설치됨 ($(rpmbuild --version | head -1))"
fi

if [ "$COMPAT_MODE" = "on" ]; then
    echo ""
    echo "단계 0-1: OL10 호스트용 legacy 빌드 도구 확인..."

    REQUIRED_TOOLS=(patch tar gzip bzip2 xz sed awk grep find cpio rpm2cpio)
    MISSING_TOOLS=()

    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            MISSING_TOOLS+=("$tool")
        fi
    done

    if [ "${#MISSING_TOOLS[@]}" -gt 0 ]; then
        echo "경고: 누락된 legacy 도구: ${MISSING_TOOLS[*]}"
        echo "권장 설치 명령:"
        echo "  sudo dnf install -y patch tar gzip bzip2 xz gawk grep findutils cpio rpm-build redhat-rpm-config"

        if command -v dnf &> /dev/null; then
            echo "legacy 도구를 자동 설치하시겠습니까? (y/n)"
            read -r -p "선택: " compat_install
            if [ "$compat_install" = "y" ] || [ "$compat_install" = "Y" ]; then
                sudo dnf install -y patch tar gzip bzip2 xz gawk grep findutils cpio rpm-build redhat-rpm-config || true
            fi
        fi
    else
        echo "legacy 도구 확인 완료"
    fi

    echo "적용 매크로 오버라이드: ${RPMBUILD_COMPAT_DEFINES[*]}"
fi

echo ""
echo "단계 1: SRPM 파일 다운로드 중..."

if [ -z "$SRPM_URL" ]; then
    echo "오류: SRPM 파일을 찾을 수 없습니다"
    cd /
    rm -rf "$WORK_DIR"
    exit 1
fi

SRPM_BASENAME="$(basename "$SRPM_URL")"
LOCAL_SRPM=""

# 동일 버전 SRPM이 있으면 재사용
if [ "$NO_CACHE" != "on" ]; then
    if [ -f "$START_DIR/$SRPM_BASENAME" ]; then
        LOCAL_SRPM="$START_DIR/$SRPM_BASENAME"
    elif [ -f "$CACHE_DIR/$SRPM_BASENAME" ]; then
        LOCAL_SRPM="$CACHE_DIR/$SRPM_BASENAME"
    fi
fi

if [ -n "$LOCAL_SRPM" ]; then
    echo "기존 SRPM 재사용: $LOCAL_SRPM"
    cp -f "$LOCAL_SRPM" "$SRPM_BASENAME"
else
    if [ "$NO_CACHE" = "on" ]; then
        echo "--no-cache 옵션 활성화: 기존 SRPM 재사용 없이 새로 다운로드합니다."
    fi
    if wget -v "$SRPM_URL"; then
        echo "다운로드 성공"
        cp -f "$SRPM_BASENAME" "$CACHE_DIR/$SRPM_BASENAME"
        echo "캐시에 저장: $CACHE_DIR/$SRPM_BASENAME"
    else
        echo "오류: SRPM 파일 다운로드 실패"
        echo "URL: $SRPM_URL"
        cd /
        rm -rf "$WORK_DIR"
        exit 1
    fi
fi

# RPM 파일 설치 (rpmbuild 디렉터리 생성)
echo ""
echo "단계 2: SRPM 설치 중 (rpm -ivh)..."
RPMBUILD_DIR="$HOME/rpmbuild"

echo "SRPM 설치 시도 (rpm -ivh)..."
if rpm -ivh "$SRPM_BASENAME"; then
    echo "SRPM 설치 성공 (rpm -ivh)"
else
    echo "rpm -ivh 실패. rpm2cpio로 수동 추출 중..."

    if [ ! -d "$RPMBUILD_DIR/SPECS" ]; then
        mkdir -p "$RPMBUILD_DIR"/{SPECS,SOURCES,BUILD,RPMS,SRPMS}
        echo "rpmbuild 디렉터리 생성: $RPMBUILD_DIR"
    fi

    if ! command -v rpm2cpio &> /dev/null; then
        echo "rpm2cpio 설치 중..."
        if command -v dnf &> /dev/null; then
            sudo dnf install -y rpm2cpio > /dev/null 2>&1
        elif command -v yum &> /dev/null; then
            sudo yum install -y rpm2cpio > /dev/null 2>&1
        fi
    fi

    if command -v rpm2cpio &> /dev/null; then
        rpm2cpio "$SRPM_BASENAME" | cpio -idmv > /dev/null 2>&1

        if ls *.spec >/dev/null 2>&1; then
            mv *.spec "$RPMBUILD_DIR/SPECS/" 2>/dev/null
            echo "SPEC 파일 이동 완료"
        fi

        if ls *.tar* >/dev/null 2>&1 || ls *.patch* >/dev/null 2>&1 || ls *.gz >/dev/null 2>&1; then
            mv *.tar* *.patch* *.gz *.bz2 *.xz "$RPMBUILD_DIR/SOURCES/" 2>/dev/null || true
            echo "소스 파일 이동 완료"
        fi

        echo "rpm2cpio 추출 성공"
    else
        echo "경고: rpm2cpio를 사용할 수 없습니다. SPEC 파일만 찾아 사용합니다."
    fi
fi

# rpmbuild 디렉터리 확인
if [ ! -d "$RPMBUILD_DIR" ] || [ ! -d "$RPMBUILD_DIR/SPECS" ]; then
    echo "오류: $RPMBUILD_DIR 디렉터리 설정 실패"
    cd /
    rm -rf "$WORK_DIR"
    exit 1
fi

echo "rpmbuild 디렉터리 확인: $RPMBUILD_DIR"

# SPEC 파일 찾기
echo ""
echo "단계 3: SPEC 파일 검색 중..."
SPEC_FILES=$(find "$RPMBUILD_DIR/SPECS" -name "*.spec" 2>/dev/null)

if [ -z "$SPEC_FILES" ]; then
    echo "오류: SPEC 파일을 찾을 수 없습니다"
    cd /
    rm -rf "$WORK_DIR"
    exit 1
fi

SPEC_FILE=""
PREFERRED_SPEC="$RPMBUILD_DIR/SPECS/${PACKAGE_BASENAME}.spec"

if [ -f "$PREFERRED_SPEC" ]; then
    SPEC_FILE="$PREFERRED_SPEC"
else
    for spec in $SPEC_FILES; do
        spec_basename=$(basename "$spec" .spec)
        if [ "$spec_basename" = "$PACKAGE_BASENAME" ]; then
            SPEC_FILE="$spec"
            break
        fi
    done
fi

if [ -z "$SPEC_FILE" ]; then
    SPEC_FILE=$(echo "$SPEC_FILES" | head -1)
    echo "경고: 정확한 SPEC 파일을 찾지 못했습니다. 첫 번째 파일 사용: $SPEC_FILE"
else
    echo "SPEC 파일 찾음: $SPEC_FILE"
fi

if [ -n "$CHANGELOG_TERM" ]; then
    CHANGELOG_RESULT=0
    search_spec_changelog "$SPEC_FILE" "$CHANGELOG_TERM" || CHANGELOG_RESULT=$?

    if [ "$CHANGELOG_ONLY" = "on" ]; then
        echo ""
        echo "--changelog-only 옵션: changelog 검색만 수행하고 종료합니다."
        cd /
        rm -rf "$WORK_DIR"
        exit "$CHANGELOG_RESULT"
    fi
fi

# rpmbuild 실행
echo ""
echo "단계 4: rpmbuild -bp 실행 중..."
cd "$RPMBUILD_DIR" || {
    echo "오류: $RPMBUILD_DIR 디렉터리로 이동할 수 없습니다"
    cd /
    rm -rf "$WORK_DIR"
    exit 1
}

SPEC_RELATIVE_PATH="./SPECS/$(basename "$SPEC_FILE")"
echo "명령어: rpmbuild ${RPMBUILD_COMPAT_DEFINES[*]} -bp $SPEC_RELATIVE_PATH --nodeps"
echo ""

if rpmbuild "${RPMBUILD_COMPAT_DEFINES[@]}" -bp "$SPEC_RELATIVE_PATH" --nodeps; then
    echo ""
    echo "rpmbuild 성공"
else
    echo ""
    echo "경고: rpmbuild 실행 중 오류 발생"
    echo "오래된 EL5/6/7 spec을 OL10에서 처리할 때 매크로나 패키지 차이로 실패할 수 있습니다."
    echo "BuildRequires와 무관하게 원본 소스 코드만 추출하는 fallback을 시도합니다."

    if extract_source_archive "$RPMBUILD_DIR/SOURCES" "$RPMBUILD_DIR/BUILD" "$PACKAGE_BASENAME"; then
        echo "소스 코드 fallback 추출 성공"
    else
        echo "소스 코드 fallback 추출도 실패했습니다"
    fi
fi

# 결과 디렉터리 구조 표시
echo ""
echo "======================================"
echo "빌드 결과 디렉터리 구조"
echo "======================================"
echo "Base Directory: $RPMBUILD_DIR"
echo ""

if [ -d "$RPMBUILD_DIR/BUILD" ]; then
    echo "BUILD 디렉터리 내용:"
    ls -la "$RPMBUILD_DIR/BUILD/" 2>/dev/null | head -20
    echo ""
fi

if [ -d "$RPMBUILD_DIR/BUILD/${PACKAGE_BASENAME}-source-extracted" ]; then
    echo "직접 추출된 소스 디렉터리:"
    ls -la "$RPMBUILD_DIR/BUILD/${PACKAGE_BASENAME}-source-extracted" 2>/dev/null | head -20
    echo ""
fi

echo "SOURCES 디렉터리 내용:"
ls -la "$RPMBUILD_DIR/SOURCES/" 2>/dev/null | head -10
echo ""

echo "SPECS 디렉터리 내용:"
ls -la "$RPMBUILD_DIR/SPECS/" 2>/dev/null | head -10
echo ""

echo "======================================"
echo "빌드 완료"
echo "======================================"
echo ""
echo "다음 단계:"
echo "1. BUILD 디렉터리에서 소스코드 확인: $RPMBUILD_DIR/BUILD/"
echo "2. SPEC 파일 확인: $SPEC_FILE"
if [ -d "$RPMBUILD_DIR/BUILD/${PACKAGE_BASENAME}-source-extracted" ]; then
    echo "3. fallback 추출 디렉터리 확인: $RPMBUILD_DIR/BUILD/${PACKAGE_BASENAME}-source-extracted/"
fi
echo ""

# 임시 작업 디렉터리 정리
cd /
rm -rf "$WORK_DIR"

exit 0
