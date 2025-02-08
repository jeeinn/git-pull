#!/bin/bash

# 定义颜色代码
COLOR_RESET="\033[0m" # reset
COLOR_INFO="\033[34m" # blue
COLOR_SUCCESS="\033[32m" # green
COLOR_WARN="\033[33m" # yellow
COLOR_ERROR="\033[31m" # red

# 日志函数
log() {
    local level=$1
    local message=$2
    local color
    local ts=$(date +"%Y-%m-%d %H:%M:%S.%3N")

    case $level in
        "INFO")    color=$COLOR_INFO ;;
        "SUCCESS") color=$COLOR_SUCCESS ;;
        "WARN")    color=$COLOR_WARN ;;
        "ERROR")   color=$COLOR_ERROR ;;
        *)         color=$COLOR_RESET ;;
    esac

    echo -e "${color}[${ts}] [${level}] ${message}${COLOR_RESET}"
}

# 检查 git 仓库
is_git_repo() {
    local repo_path=$1
    cd "$repo_path" || {
        log "ERROR" "目录访问失败: $repo_path"
        return 1
    }
    git rev-parse --is-inside-work-tree &>/dev/null
    return $?
}

# 获取本地分支
get_local_branches() {
    git branch --format='%(refname:short)' | grep -v HEAD
}

# 安全回滚
rollback() {
    local target=$1
    log "INFO" "执行回滚到 $target"
    if ! git reset --hard "$target"; then
        log "ERROR" "回滚操作失败！请手动处理"
        return 1
    fi
}

# 处理 git 仓库
process_git_repo() {
    local repo_path=$1
    local original_dir=$(pwd)

    # cd "$repo_path" || {
    #     log "ERROR" "目录访问失败: $repo_path"
    #     return 1
    # }

    if ! is_git_repo "$repo_path"; then
        log "WARN" "非 git 项目: $repo_path"
        cd "$original_dir" || return 1  # 确保回到原始目录
        return 0
    fi

    log "INFO" "处理仓库: $(basename "$repo_path")"
    local original_branch=$(git symbolic-ref --short HEAD)
    local branches=()
    mapfile -t branches < <(get_local_branches)

    for branch in "${branches[@]}"; do
        log "INFO" "处理分支: $branch"
        git checkout "$branch" || {
            log "ERROR" "分支切换失败: $branch"
            continue
        }

        local current_commit=$(git rev-parse HEAD)
        local stash_name="auto-stash-${branch}-$(date +%s)"
        local stash_ref=""

        # 增强型 stash 处理（包含未跟踪文件）
        if ! git diff-index --quiet HEAD -- || [ -n "$(git ls-files --others --exclude-standard)" ]; then
            log "WARN" "检测到未提交修改或未跟踪文件，创建安全 stash"

            # 创建并存储 stash
            local stash_hash=$(git stash create --include-untracked "$stash_name")
            [ -z "$stash_hash" ] && {
                log "ERROR" "stash 创建失败，跳过分支处理"
                continue
            }

            if ! git stash store -m "$stash_name" "$stash_hash"; then
                log "ERROR" "stash 存储失败，跳过分支处理"
                continue
            fi

            # 获取存储的 stash 引用
            stash_ref=$(git stash list | grep -m1 ": ${stash_name}" | awk -F': ' '{print $1}')
            [ -z "$stash_ref" ] && {
                log "ERROR" "无法定位 stash 引用，跳过清理操作"
                continue
            }

            # 安全重置工作区
            if ! git reset --hard HEAD; then
                log "ERROR" "工作区重置失败，跳过分支处理"
                continue
            fi
            log "INFO" "Stash 保存成功 (ref: $stash_ref)"
        fi

        # 执行更新（带冲突保护）
        log "INFO" "执行 git pull"
        if git pull; then
            log "SUCCESS" "更新成功"
        else
            log "ERROR" "更新失败，执行回滚"
            if ! rollback "$current_commit"; then
                log "ERROR" "回滚失败！请立即手动处理"
                cd "$original_dir" || return 1  # 确保回到原始目录
                return 1
            fi
            git checkout "$original_branch"
            log "WARN" "请手动处理冲突: $repo_path"
            cd "$original_dir" || return 1  # 确保回到原始目录
            return 1
        fi

        # 安全应用 stash（使用引用格式）
        if [ -n "$stash_ref" ]; then
            log "INFO" "尝试应用 $stash_ref"
            if git stash apply --index "$stash_ref"; then
                log "SUCCESS" "成功应用 stash"
                if git stash drop "$stash_ref"; then
                    log "INFO" "已清理临时 stash"
                else
                    log "WARN" "stash 清理失败（可安全忽略）"
                fi
            else
                log "ERROR" "自动应用失败，保留 stash"
                log "WARN" "请手动处理：git stash apply $stash_ref"
                log "WARN" "查看差异：git diff $stash_ref"
                cd "$original_dir" || return 1  # 确保回到原始目录
                return 1
            fi
        fi
    done

    git checkout "$original_branch"
    cd "$original_dir" || return 1
    log "SUCCESS" "仓库处理完成: $repo_path"
    return 0
}

# 主逻辑
main() {
    local input_dir=$1
    local target_dir="."
    [ -n "$input_dir" ] && target_dir=$(readlink -f "$input_dir")

    if is_git_repo "$target_dir"; then
        process_git_repo "$target_dir"
    else
        log "INFO" "扫描子目录..."
        find "$target_dir" -maxdepth 1 -type d | while read -r subdir; do
            [ "$subdir" = "$target_dir" ] && continue
            process_git_repo "$subdir"
        done
    fi
}

main "$@"