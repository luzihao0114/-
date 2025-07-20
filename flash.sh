#!/data/data/com.termux/files/usr/bin/bash

# 彩色输出增强（保留视觉引导）
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
cyan() { echo -e "\033[36m$1\033[0m"; }
purple() { echo -e "\033[35m$1\033[0m"; }

# 核心依赖安装（仅必要工具，确保可用）
fix_deps() {
    yellow "🚀 部署环境..."
    local deps=("android-tools" "termux-api")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            yellow "📦 安装 $dep..."
            pkg install -y "$dep" >/dev/null 2>&1 || {
                red "❌ $dep安装失败！手动修复：pkg install -y $dep"
                exit 1
            }
        fi
    done
    green "✅ 环境就绪！"
}  # 新增：补全函数闭合括号


# 核心依赖安装（仅必要工具，确保可用）
fix_deps() {
    yellow "🚀 部署环境..."
    local deps=("android-tools" "termux-api")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            yellow "📦 安装 $dep..."
            pkg install -y "$dep" >/dev/null 2>&1 || {
                red "❌ $dep安装失败！手动修复：pkg install -y $dep"
                exit 1
            }
        fi
    done
    green "✅ 环境就绪！"
}  # 新增：补全函数闭合括号


# 智能文件选择（自动弹窗+手动输入，带类型校验）
select_file() {
    # 自动弹窗选择（termux-api支持）
    if command -v termux-file-editor >/dev/null 2>&1; then
        local temp=$(mktemp)
        termux-file-editor "$temp" >/dev/null 2>&1
        local path=$(cat "$temp" 2>/dev/null)
        rm -f "$temp"
        # 转换为Termux可识别路径（兼容多种存储路径格式）
        path=$(echo "$path" | sed -e "s|/storage/emulated/0|/sdcard|g" -e "s|/mnt/sdcard|/sdcard|g")
        if [ -f "$path" ] && echo "$path" | grep -q "\.img$\|\.zip$"; then
            echo "$path"
            return 0
        else
            yellow "⚠ 请选择.img（镜像）或.zip（刷机包）"
        fi
    fi
    # 手动输入（带路径引导）
    yellow "📌 请输入文件路径（示例：/storage/emulated/0/boot.img 或 /sdcard/boot.img）"
    while true; do
        read -p "📂 路径: " path
        # 自动补全/sdcard前缀（兼容相对路径）
        [[ "$path" != /sdcard/* && "$path" != /* ]] && path="/sdcard/$path"
        # 二次转换路径（避免用户输入原始路径）
        path=$(echo "$path" | sed -e "s|/storage/emulated/0|/sdcard|g" -e "s|/mnt/sdcard|/sdcard|g")
        if [ -f "$path" ]; then
            if echo "$path" | grep -q "\.img$\|\.zip$"; then
                echo "$path"
                return 0
            else
                red "❌ 仅支持.img或.zip文件！"
            fi
        else
            red "❌ 路径无效，请重新输入"
        fi
    done
}

# 分区智能识别（支持10+分区，核心功能保留）
guess_partition() {
    local img_name=$(basename "$1" | tr '[:upper:]' '[:lower:]')
    case $img_name in
        *boot*)    echo "boot"    ;;
        *lk*)      echo "lk"      ;;
        *recovery*)echo "recovery";;
        *system*)  echo "system"  ;;
        *vendor*)  echo "vendor"  ;;
        *dtbo*)    echo "dtbo"    ;;
        *vbmeta*)  echo "vbmeta"  ;;
        *super*)   echo "super"   ;;
        *init*)    echo "init"    ;;
        *logo*)    echo "logo"    ;;
        *userdata*)echo "userdata";;
        *)          echo "无法识别，请手动输入" ;;
    esac
}

# 设备智能检测（区分ADB/Fastboot，带排错）
check_device() {
    local retries=3  # 重试3次
    local delay=2    # 每次重试间隔2秒
    local adb_dev=""
    local fb_dev=""
    
    for ((i=1; i<=retries; i++)); do
        adb_dev=$(adb devices | grep -v "List" | grep -v "^$")
        fb_dev=$(fastboot devices | grep -v "^$")
        if [ -n "$adb_dev" ] || [ -n "$fb_dev" ]; then
            break  # 检测到设备则退出重试
        fi
        if [ $i -lt $retries ]; then
            yellow "🔍 正在重试检测设备（$i/$retries）..."
            sleep $delay
        fi
    done
    
    if [ -n "$adb_dev" ]; then
        green "✅ ADB设备已连接"
        return 0
    elif [ -n "$fb_dev" ]; then
        green "✅ Fastboot设备已连接"
        return 0
    else
        red "❌ 未检测到设备！请检查："
        red " 1. 手机已开启「USB调试」（设置→开发者选项）"
        red " 2. 数据线已连接，且手机已授权调试（弹窗中点击允许）"
        red " 3. 若刷Fastboot，确保手机已进入Fastboot模式"
        return 1
    fi
}

# 常规刷机（保留自动识别+手动修改+错误处理＋文件后缀识别)
fastboot_flash() {
    while true; do
        clear
        purple "======================"
        purple "  常规刷机模式       "
        purple "======================"
        yellow "1. 刷写镜像文件（.img → Fastboot）"
        yellow "2. 刷写ZIP包（.zip → Recovery）"
        yellow "3. 批量刷写镜像（文件夹 → Fastbootd）"  # 优化为文件夹批量刷写
        yellow "4. 返回主菜单"
        purple "======================"
        read -p "🔢 选择 [1-4]: " opt
        
        case $opt in
            1)  # 1. 刷写镜像文件（.img → Fastboot）原逻辑
                # 选择文件并强制校验.img后缀
                img=$(select_file)
                if echo "$img" | grep -qv "\.img$"; then
                    red "❌ Fastboot模式仅支持 .img 文件！"
                    read -p "按回车返回..."
                    continue
                fi
                
                # 自动识别分区（支持手动修改）
                part=$(guess_partition "$img")
                green "✅ 镜像路径: $img"
                green "💡 自动识别分区：$part（回车确认，或输入新分区）"
                read -p "📌 分区名: " input_part
                part=${input_part:-$part}  # 空输入则用自动识别结果
                
                # 检测设备连接状态
                if ! check_device; then
                    read -p "按回车返回..."
                    continue
                fi
                
                # 执行Fastboot刷写 + 结果提示
                fastboot flash "$part" "$img" && green "🎉 刷写成功！" || {
                    red "❌ 刷写失败！可能原因："
                    red " 1. 设备未进入Fastboot模式"
                    red " 2. 分区名错误或文件损坏"
                }
                read -p "按回车返回..."
                ;;
            
            2)  # 2. 刷写ZIP包（.zip → Recovery）原逻辑
                # 选择文件并强制校验.zip后缀
                zip=$(select_file)
                if echo "$zip" | grep -qv "\.zip$"; then
                    red "❌ Recovery模式仅支持 .zip 文件！"
                    read -p "按回车返回..."
                    continue
                fi
                
                # 显示ZIP包路径
                green "✅ ZIP包路径: $zip"
                
                # 检测设备连接状态
                if ! check_device; then
                    read -p "按回车返回..."
                    continue
                fi
                
                # 执行ADB sideload刷写 + 结果提示
                adb sideload "$zip" && green "🎉 刷写成功！" || {
                    red "❌ 刷写失败！可能原因："
                    red " 1. 设备未进入Recovery模式"
                    red " 2. 未开启ADB sideload或包不兼容"
                }
                read -p "按回车返回..."
                ;;
            3)  # Fastbootd模式批量刷写文件夹内所有.img（全量处理，不跳过）
    # 选择文件夹（逻辑不变）
    yellow "📂 请选择存放镜像的文件夹（仅支持包含.img文件的目录）"
    local folder
    if command -v termux-file-editor >/dev/null 2>&1; then
        local temp=$(mktemp)
        termux-file-editor "$temp" >/dev/null 2>&1
        folder=$(dirname "$(cat "$temp" 2>/dev/null)")
        rm -f "$temp"
        folder=$(echo "$folder" | sed "s|/storage/emulated/0|/sdcard|g")
    else
        yellow "📌 请输入文件夹路径（示例：/sdcard/images）"
        while true; do
            read -p "📂 文件夹路径: " folder
            [[ "$folder" != /sdcard/* && "$folder" != /* ]] && folder="/sdcard/$folder"
            if [ -d "$folder" ]; then
                break
            else
                red "❌ 无效文件夹！请重新输入"
            fi
        done
    fi

    # 检查文件夹内.img文件（逻辑不变）
    local img_files=$(find "$folder" -maxdepth 1 -type f -name "*.img" | sort)
    if [ -z "$img_files" ]; then
        red "❌ 文件夹内未找到任何.img文件！"
        read -p "按回车返回..."
        continue
    fi

    # 显示待刷写文件列表（逻辑不变）
    green "✅ 检测到以下镜像文件（将按顺序刷写）："
    echo "$img_files" | while read -r img; do
        echo "  - $(basename "$img")"
    done
    yellow "⚠ 注意：请确保设备已进入Fastbootd模式！"
    read -p "确认开始刷写？（y/n）: " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        yellow "⚠ 已取消刷写"
        read -p "按回车返回..."
        continue
    fi

    # 检测Fastbootd模式（逻辑不变）
    if ! fastboot devices | grep -q "fastboot"; then
        red "❌ 未检测到Fastbootd设备！请先进入Fastbootd模式"
        read -p "按回车返回..."
        continue
    fi

    # 批量刷写（核心优化：全量处理，不跳过无法识别的分区）
    local total=$(echo "$img_files" | wc -l)
    local count=1
    green "🚀 开始批量刷写（共$total个文件）..."
    echo "$img_files" | while read -r img; do
        local img_name=$(basename "$img")
        local part=$(guess_partition "$img")  # 先尝试自动识别
        
        # 若无法自动识别，提示手动输入分区名
        if [ "$part" = "无法识别，请手动输入" ]; then
            yellow "\n⚠ $img_name 无法自动识别分区，请手动输入"
            while true; do
                read -p "📌 请输入该文件对应的分区名: " input_part
                if [ -n "$input_part" ]; then  # 确保用户输入了内容
                    part="$input_part"
                    break
                else
                    red "❌ 分区名不能为空，请重新输入"
                fi
            done
        fi

        # 执行刷写（无论自动/手动识别，均处理）
        green "\n===== 刷写第$count/$total个：$img_name（分区：$part） ====="
        fastboot flash "$part" "$img"
        if [ $? -eq 0 ]; then
            green "✅ $img_name 刷写成功"
        else
            red "❌ $img_name 刷写失败！已记录，继续下一个"
        fi
        ((count++))
    done

    green "\n📊 批量刷写完成！所有文件已处理（含手动输入分区的文件）"
    red "⚠ 提示：若有失败文件，建议单独检查分区名或文件完整性"
    read -p "按回车返回..."
    ;;

            
            4) break ;;
            *) red "❌ 无效选项！"; sleep 1 ;;
        esac
    done
}


# 设备控制中心（新增Fastbootd重启选项）
device_control() {
    while true; do
        clear
        cyan "======================"
        cyan "  设备控制中心       "
        cyan "======================"
        yellow "1. 查看设备连接状态"
        yellow "2. 重启到系统"
        yellow "3. 重启到Recovery"
        yellow "4. 重启到Fastboot"
        yellow "5. 重启到Fastbootd"  # 新增选项
        yellow "6. 返回主菜单"        # 序号顺延
        cyan "======================"
        read -p "🔢 选择 [1-6]: " opt  # 选项范围更新
        
        case $opt in
            1)
                adb devices
                fastboot devices
                read -p "按回车返回..."
                ;;
            2)
                if check_device; then
                    adb reboot && green "🔄 已发送重启指令（系统）..."
                else
                    red "❌ 未连接设备！"
                fi
                sleep 2; break
                ;;
            3)
                if check_device; then
                    adb reboot recovery && green "🔄 已发送重启指令（Recovery）..."
                else
                    red "❌ 未连接设备！"
                fi
                sleep 2; break
                ;;
            4)
                if check_device; then
                    adb reboot bootloader && green "🔄 已发送重启指令（Fastboot）..."
                else
                    red "❌ 未连接设备！"
                fi
                sleep 2; break
                ;;
            5)  # 新增Fastbootd重启逻辑
                if check_device; then
                    adb reboot fastboot && green "🔄 已发送重启指令（Fastbootd）..."
                    yellow "💡 提示：Fastbootd启动较慢，请耐心等待30秒左右"
                else
                    red "❌ 未连接设备！"
                fi
                sleep 3; break  # 延长等待时间，适配Fastbootd启动速度
                ;;
            6) break ;;  # 返回主菜单序号顺延
            *) red "❌ 无效选项！"; sleep 1 ;;
        esac
    done
}

# 主菜单（保留原有结构）
main() {
    fix_storage
    fix_deps
    while true; do
        clear
        purple "======================"
        purple "  砚风工具箱1039049229     "
        purple "======================"
        yellow "1. 常规刷机（Fastboot/Recovery）"
        yellow "2. 设备控制中心"
        yellow "3. 退出工具"
        purple "======================"
        read -p "🔢 选择功能 [1-3]: " choice
        
        case $choice in
            1) fastboot_flash ;;
            2) device_control ;;
            3) green "👋 再见！"; exit 0 ;;
            *) red "❌ 无效选项，请重试！"; sleep 1 ;;
        esac
    done
}

# 启动脚本
main
