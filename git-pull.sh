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
    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")

    case $level in
        "INFO")    color=$COLOR_INFO ;;
        "SUCCESS") color=$COLOR_SUCCESS ;;
        "WARN")    color=$COLOR_WARN ;;
        "ERROR")   color=$COLOR_ERROR ;;
        *)         color=$COLOR_RESET ;;
    esac

    echo -e "${color}[${ts}] [${level}] ${message}${COLOR_RESET}"
}

# 检查是否为 git 仓库
is_git_repo() {
    local repo_path=$1
    local original_dir
    original_dir=$(pwd)

    # 验证路径是否存在且为目录
    if [[ ! -d "$repo_path" ]]; then
        log "ERROR" "目录访问失败: $repo_path"
        return 1
    fi

    # 尝试进入目录，如果失败则记录错误并返回 1
    if ! cd "$repo_path"; then
        log "ERROR" "无法进入目录: $repo_path"
        return 1
    fi

    # 检查是否在 git 工作树内，将标准输出和标准错误输出都重定向到 /dev/null
    if ! git rev-parse --is-inside-work-tree &> /dev/null; then
        cd "$original_dir" || return 1
        return 1
    fi

    cd "$original_dir" || return 1
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
        # 回滚失败应为极小概率
        log "ERROR" "回滚操作失败！"
        log "WARN" ""
        log "WARN" "以下是一些可能的处理方法："
        log "WARN" "1. 手动重置工作区 git reset --hard HEAD"
        log "WARN" "2. 恢复 stash "
        log "WARN" "   - 查看：git stash list"
        log "WARN" "   - 应用：git stash apply stash{0}"
        return 1
    fi
    log "INFO" "回滚成功"
    return 0
}

# 恢复 stash
restore_stash() {
    local stash_ref=$1
    local stash_name=$2

    log "INFO" "尝试应用 $stash_ref"
    if ! git stash apply --index "$stash_ref"; then
        log "ERROR" "自动应用失败，保留 stash"
        log "WARN" ""
        log "WARN" "检测到已保存的 stash 有可恢复内容"
        log "WARN" "   - 查看: git stash list"
        log "WARN" "   - 查看差异: git diff $stash_ref"
        log "WARN" "   - 重新应用 $stash_name ：git stash apply $stash_ref"
        return 1
    fi

    log "INFO" "成功应用 stash"
    if git stash drop "$stash_ref"; then
        log "INFO" "已清理临时 stash"
    else
        log "WARN" "Stash 清理失败（可安全忽略）"
    fi
    return 0
}

# 处理 git 仓库
process_git_repo() {
    local repo_path=$1
    local original_dir
    original_dir=$(pwd)

    # 检查是否为 git 仓库
    if ! is_git_repo "$repo_path"; then
        log "WARN" "非 GIT 项目: $repo_path"
        return 1
    fi

    log "INFO" "===================================="
    log "SUCCESS" "开始处理本地仓库: $(basename "$repo_path")"
    cd "$repo_path" || {
        log "ERROR" "目录访问失败: $repo_path"
        return 1
    }

    local original_branch
    original_branch=$(git symbolic-ref --short HEAD)
    local branches=()
    local original_branch_found=false

    # 重构分支排序逻辑：原始分支排首位
    while IFS= read -r branch; do
        if [[ "$branch" == "$original_branch" ]]; then
            branches=("$branch" "${branches[@]}") # 插入数组开头
            original_branch_found=true
        else
            branches+=("$branch")
        fi
    done < <(get_local_branches)

    # 若原始分支未在分支列表中（异常情况）
    if ! $original_branch_found; then
        log "WARN" "原始分支 $original_branch 未在本地分支列表中"
        branches=("$original_branch" "${branches[@]}")
    fi

    # 状态追踪变量
    local global_stash_ref=""  # 用于记录原始分支的stash ref
    local global_stash_name="" # 用于记录原始分支的stash name

    for branch in "${branches[@]}"; do
        log "INFO" "开始处理本地分支: ${branch}"
        # 切换分支，如果失败继续处理下一个分支
        if ! git checkout "$branch"; then
            log "ERROR" "分支切换失败: ${branch}"
            continue
        fi

        local current_commit
        current_commit=$(git rev-parse HEAD)

        # 已确保首次进入原始分支且仅在原始分支处理全局 stash （包含未跟踪文件）
        # 后续分支将基于干净工作区
        if [[ "$branch" == "$original_branch" ]]; then
            if ! git diff-index --quiet HEAD -- || [ -n "$(git ls-files --others --exclude-standard)" ]; then
                log "WARN" "[当前仓库] 检测到未提交修改或未跟踪文件"
                log "INFO" "尝试自动解决，开始安全创建全局 stash"

                # 创建并存储 stash
                global_stash_name="GLOBAL_STASH_${original_branch}_$(date +%s)"
                if ! git stash push --include-untracked --message "$global_stash_name"; then
                    log "ERROR" "全局 stash 创建失败，不再处理本仓库"
                    cd "$original_dir" || return 1 # 确保回到原始目录
                    return 1
                fi

                # 获取存储的 stash 引用
                global_stash_ref=$(git stash list | grep -m1 "$global_stash_name" | awk -F': ' '{print $1}')
                if [ -z "$global_stash_ref" ]; then
                    log "ERROR" "无法定位 stash 引用，不再处理本仓库"
                    cd "$original_dir" || return 1 # 确保回到原始目录
                    return 1
                fi
                log "INFO" "全局 stash 创建成功 ${global_stash_name} (ref: ${global_stash_ref})"
            fi
        fi

        # 安全重置工作区
        if ! git reset --hard HEAD; then
            log "WARN" "工作区重置失败，跳过分支处理（可安全忽略）"
            continue
        fi

        log "INFO" "开始执行 git pull"
        if ! git pull; then
            log "INFO" "本地分支更新失败，执行回滚"
            if ! rollback "$current_commit"; then
                log "ERROR" "回滚失败，不再处理本仓库"
                cd "$original_dir" || return 1 # 确保回到原始目录
                return 1
            fi
            log "ERROR" "执行 git pull 失败！"
            log "WARN" "请注意检查上述失败原因"
            log "INFO" "Repo: ${repo_path} (Branch: ${branch})"
        else
            log "SUCCESS" "本地分支更新成功: $branch"
        fi
    done

    # 返回原始分支并判断 stash 恢复
    if ! git checkout "$original_branch"; then
        log "ERROR" "返回原始分支失败: ${original_branch}"
        if [ -n "$global_stash_ref" ]; then
            log "WARN" "可通过以下命令手动恢复：git stash apply ${global_stash_ref} （${global_stash_name})"
        fi
    else
        log "INFO" "返回原始分支"

        # 安全应用 stash（使用引用格式）
        if [ -n "$global_stash_ref" ]; then
            if ! restore_stash "$global_stash_ref" "$global_stash_name"; then
                log "WARN" "当前分支${original_branch}"
            fi
        fi
    fi

    cd "$original_dir" || return 1
    log "SUCCESS" "仓库处理完成: $repo_path"
    return 0
}

# 检查所需命令是否存在
check_commands() {
    local command_list=("$1")
    local commands_not_found=""

    # 遍历命令列表
    for command in "${command_list[@]}"; do
        # 检查命令是否可用
        if ! type -t "$command" > /dev/null; then
            # 如果命令不可用，记录下来
            commands_not_found+="$command "
        fi
    done

    # 如果有命令不存在，输出错误信息并退出
    if [ -n "$commands_not_found" ]; then
        log "ERROR" "以下命令未安装或不可用: ${commands_not_found}"
        exit 1
    fi
}

# 主逻辑
main() {
    local input_dir=$1
    local target_dir="."
    # 如果输入目录不为空，则将其转换为绝对路径
    [ -n "$input_dir" ] && target_dir=$(readlink -f "$input_dir")

    # 检查所需命令是否存在
    check_commands awk date find git grep readlink

    # 记录开始时间
    local start_time
    start_time=$(date +"%s")

    if is_git_repo "$target_dir"; then
        log "SUCCESS" "开始处理当前目录..."
        process_git_repo "$target_dir"
    else
        log "SUCCESS" "开始扫描一级子目录..."
        # 查找目标目录下的一级子目录
        find "$target_dir" -maxdepth 1 -type d | while read -r subdir; do
            # 跳过目标目录本身
            [ "$subdir" = "$target_dir" ] && continue
            process_git_repo "$subdir"
        done
        log "SUCCESS" "程序执行结束"
    fi

    # 记录结束时间
    local end_time
    end_time=$(date +"%s")

    # 计算运行时间
    local runtime=$((end_time - start_time))
    log "INFO" "程序运行时间: $runtime 秒"
}

main "$@"
