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
    # 尝试进入目录，如果失败则记录错误并返回 1
    if ! cd "$repo_path" 2>/dev/null; then
        log "ERROR" "目录访问失败: $repo_path"
        return 1
    fi
    # 检查是否在 git 工作树内，将标准输出和标准错误输出都重定向到 /dev/null
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        cd - >/dev/null  # 回到原来的目录
        return 1
    fi
    cd - >/dev/null  # 回到原来的目录
    return 0
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
    return 0
}

# 处理 git 仓库
process_git_repo() {
    local repo_path=$1
    local original_dir=$(pwd)

    # 检查是否为 git 仓库
    if ! is_git_repo "$repo_path"; then
        log "WARN" "非 git 项目: $repo_path"
        return 0
    fi

    log "INFO" "===================================="
    log "INFO" "处理仓库: $(basename "$repo_path")"
    cd "$repo_path" || {
        log "ERROR" "目录访问失败: $repo_path"
        return 1
    }

    local original_branch=$(git symbolic-ref --short HEAD)
    local branches=()
    # 使用 mapfile 读取本地分支到数组中
    mapfile -t branches < <(get_local_branches)

    for branch in "${branches[@]}"; do
        log "INFO" "处理分支: $branch"
        # 切换分支，如果失败则记录错误并继续处理下一个分支
        if ! git checkout "$branch"; then
            log "ERROR" "分支切换失败: $branch"
            continue
        fi

        local current_commit=$(git rev-parse HEAD)
        local stash_name="auto-stash-${branch}-$(date +%s)"
        local stash_ref=""

        # 增强型 stash 处理（包含未跟踪文件）
        if ! git diff-index --quiet HEAD -- || [ -n "$(git ls-files --others --exclude-standard)" ]; then
            log "WARN" "检测到未提交修改或未跟踪文件，开始创建安全 stash"

            # 创建并存储 stash
            local stash_hash=$(git stash create --include-untracked "$stash_name")
            if [ -z "$stash_hash" ]; then
                log "ERROR" "stash 创建失败，跳过分支处理"
                continue
            fi

            if ! git stash store -m "$stash_name" "$stash_hash"; then
                log "ERROR" "stash 存储失败，跳过分支处理"
                continue
            fi

            # 获取存储的 stash 引用
            stash_ref=$(git stash list | grep -m1 ": ${stash_name}" | awk -F': ' '{print $1}')
            if [ -z "$stash_ref" ]; then
                log "ERROR" "无法定位 stash 引用，跳过清理操作"
                continue
            fi

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
                log "WARN" "以下是一些可能的处理方法："
                log "WARN" "1. 手动重置工作区 git reset --hard HEAD"
                log "WARN" "2. 查看项目 stash 列表"
                log "WARN" "   - 查看：git stash list"
                log "WARN" "   - 查看差异：git diff $stash_ref"
                log "WARN" "   - 重新应用 $stash_name ：git stash apply $stash_ref"
                cd "$original_dir" || return 1  # 确保回到原始目录
                return 1
            fi
            log "ERROR" "git pull 失败 $repo_path，可能是无法连接到远程仓库或远程无此本地分支。"
            log "WARN" "以下是一些可能的处理方法："
            log "WARN" "1. 检查网络连接是否正常，可以尝试 ping 远程仓库的域名。例如：ping github.com"
            log "WARN" "2. 检查远程仓库的 URL 是否正确，可以使用以下命令查看并修改："
            log "WARN" "   - 查看：git remote -v"
            log "WARN" "   - 修改：git remote set-url origin <new-url>"
            log "WARN" "3. 确认远程仓库是否存在此分支，可以在远程仓库的网页界面查看分支列表。"
            log "WARN" "4. 如果是权限问题，检查你的 SSH 密钥或用户名密码是否正确。"
            log "WARN" "5. 尝试手动拉取：git fetch，然后使用 git merge 合并分支。"

            git checkout "$original_branch"
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
    # 如果输入目录不为空，则将其转换为绝对路径
    [ -n "$input_dir" ] && target_dir=$(readlink -f "$input_dir")

    if is_git_repo "$target_dir"; then
        process_git_repo "$target_dir"
    else
        log "INFO" "开始扫描一级子目录..."
        # 查找目标目录下的一级子目录
        find "$target_dir" -maxdepth 1 -type d | while read -r subdir; do
            # 跳过目标目录本身
            [ "$subdir" = "$target_dir" ] && continue
            process_git_repo "$subdir"
        done
        log "INFO" "处理完成"
    fi
}

main "$@"