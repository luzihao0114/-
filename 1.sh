#!/data/data/com.termux/files/usr/bin/bash
# 砚风工具箱（最终优化版）：功能完整、可直接使用
# ==============================================
# 基础配置与彩色输出
# ==============================================
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
cyan() { echo -e "\033[36m$1\033[0m"; }
purple() { echo -e "\033[35m$1\033[0m"; }
# 存储路径修复
fix_storage() {
    [ ! -L /sdcard ] && ln -s /storage/emulated/0 /sdcard 2>/dev/null
}
# Fastboot版本更新
update_fastboot() {
    yellow "🔧 检测fastboot版本..."
    if ! fastboot --help 2>/dev/null | grep -q "fastbootd"; then
        yellow "📥 正在更新fastboot至最新版..."
        local temp_zip=$(mktemp).zip
        if curl -sSL "https://dl.google.com/android/repository/platform-tools-latest-linux.zip" -o "$temp_zip"; then
            local temp_dir=$(mktemp -d)
            unzip -q "$temp_zip" -d "$temp_dir"
            cp "$temp_dir/platform-tools/fastboot" "$PREFIX/bin/"
            chmod +x "$PREFIX/bin/fastboot"
            rm -rf "$temp_zip" "$temp_dir"
            green "✅ fastboot已更新（支持Fastbootd）"
        else
            red "❌ fastboot更新失败，可手动更新"
        fi
    else
        green "✅ fastboot版本兼容"
    fi
}
# ==============================================
# 设备检测逻辑（柔性检测+强制执行支持）
# ==============================================
declare -A DEVICE_STATE
DEVICE_STATE["adb"]="未检测到"
DEVICE_STATE["fastboot"]="未检测到"
DEVICE_STATE["mtk"]="未检测到"
# 刷新设备状态（仅检测，不阻断）
refresh_device_state() {
    # ADB检测（宽松判断）
    local adb_out=$(adb devices 2>/dev/null | grep -v "List" | grep -v "^$")
    DEVICE_STATE["adb"]=$( [ -n "$adb_out" ] && echo "已检测到" || echo "未检测到" )
    # Fastboot检测（支持保存的路径）
    local saved_fb_path=$(cat ~/.fastboot_path 2>/dev/null)
    local fb_out=""
    if [ -n "$saved_fb_path" ]; then
        fb_out=$(termux-usb -r -e "fastboot devices" -E "$saved_fb_path" 2>/dev/null | grep -v "^$")
    else
        fb_out=$(fastboot devices 2>/dev/null | grep -v "^$")
    fi
    DEVICE_STATE["fastboot"]=$( [ -n "$fb_out" ] && echo "已检测到" || echo "未检测到" )
    # 联发科设备检测
    local mtk_out=$(find /dev/bus/usb -type c 2>/dev/null | grep -E "/00[1-9]/00[1-9]$" | head -n1)
    DEVICE_STATE["mtk"]=$( [ -n "$mtk_out" ] && echo "已检测到" || echo "未检测到" )
}
# 显示设备状态（提示可强制执行）
show_device_status() {
    refresh_device_state
    echo -e "\n\033[36m当前设备状态（仅供参考）：\033[0m"
    echo "• ADB设备：${DEVICE_STATE["adb"]}（未检测到也可尝试操作）"
    echo "• Fastboot设备：${DEVICE_STATE["fastboot"]}（未检测到也可尝试操作）"
    echo "• 联发科BROM设备：${DEVICE_STATE["mtk"]}（未检测到也可尝试操作）"
}
# 柔性确认（允许无视检测结果）
confirm_force_exec() {
    local mode=$1
    yellow "\n⚠ 工具未检测到${mode}设备，但可能实际已连接"
    read -p "是否强制执行操作？(y/n)：" confirm
    [ "$confirm" = "y" ] || [ "$confirm" = "Y" ] && return 0 || return 1
}
# 自动分区识别（核心功能，完整保留）
guess_partition() {
    local img_path="$1"
    local img_name=$(basename "$img_path")  
    local img_base="${img_name%.*}"         
    local img_lower=$(echo "$img_base" | tr '[:upper:]' '[:lower:]')  
    local part=""
    declare -A PART_MAP=(
        ["boot"]="boot"
        ["recovery"]="recovery"
        ["vendor_boot"]="vendor_boot"
        ["dtbo"]="dtbo"
        ["vbmeta"]="vbmeta"
        ["system"]="system"
        ["vendor"]="vendor"
        ["product"]="product"
        ["odm"]="odm"
        ["logo"]="logo"
        ["boot_[ab]"]="boot_a（AB设备请手动改后缀，如boot_b）"
        ["recovery_[ab]"]="recovery_a（AB设备请手动改后缀，如recovery_b）"
    )
    local candidates=()
    for key in "${!PART_MAP[@]}"; do
        if [[ "$img_lower" =~ $key ]]; then  
            candidates+=("${PART_MAP[$key]}")
        fi
    done
    if [ ${#candidates[@]} -eq 1 ]; then
        echo "${candidates[0]}"
        return 0
    elif [ ${#candidates[@]} -gt 1 ]; then
        green "检测到多个可能的分区："
        for i in "${!candidates[@]}"; do
            echo "$((i+1)). ${candidates[$i]}"
        done
        read -p "请选择分区（回车选第一个）: " idx
        idx=${idx:-1}  
        if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -le "${#candidates[@]}" ]; then
            echo "${candidates[$((idx-1))]}"
            return 0
        else
            red "⚠ 无效选择，进入手动输入模式"
        fi
    fi
    green "未自动识别分区，常见分区参考："
    echo "  boot | recovery | vendor_boot | dtbo | vbmeta | system"
    read -p "请输入分区名（必填）: " part
    if [[ "$part" =~ "userdata" ]]; then
        red "❗ 警告：刷写userdata会清除所有数据！"
        read -p "确认继续？(y/n) " confirm
        [[ "$confirm" != "y" ]] && echo "已取消" && return 1
    fi
    echo "$part"
}
# 带退出的文件选择（保留，支持IMG/ZIP）
select_file_with_exit() {
    local ext="${1:-img}"
    yellow "📂 选择 $ext 文件（输入q退出）"
    
    if command -v termux-file-editor >/dev/null; then
        local temp=$(mktemp)
        termux-file-editor "$temp" >/dev/null 2>&1
        local path=$(cat "$temp" 2>/dev/null)
        rm -f "$temp"
        [[ "$path" =~ ^[qQ]$ ]] && return
        [[ -f "$path" && "$path" =~ \.$ext$ ]] && echo "$path" && return
    fi
    
    while true; do
        read -r -p "路径（q退出）: " path
        [[ "$path" =~ ^[qQ]$ ]] && return
        [[ "$path" != /* ]] && path="/sdcard/$path"
        path=$(realpath -e "$path" 2>/dev/null)
        if [ -f "$path" ]; then
            if [[ $(echo "$path" | tr '[:upper:]' '[:lower:]') =~ \.$ext$ ]]; then
                echo "$path"
                return
            else
                red "❌ 必须是 .$ext 文件（支持大小写）"
            fi
        else
            red "❌ 路径不存在"
        fi
    done
}
# 带退出的文件夹选择（保留，批量刷写用）
select_folder_with_exit() {
    yellow "📁 选择文件夹（输入q退出）"
    if command -v termux-file-editor >/dev/null; then
        local temp=$(mktemp)
        termux-file-editor "$temp" >/dev/null 2>&1
        local path=$(cat "$temp" 2>/dev/null)
        rm -f "$temp"
        [[ "$path" =~ ^[qQ]$ ]] && return
        if [ -f "$path" ]; then
            path=$(dirname "$path")
        fi
        if [ -d "$path" ]; then
            echo "$path"
            return 0
        else
            red "❌ 选择的不是有效文件夹"
            return 1
        fi
    fi
    
    while true; do
        read -r -p "路径（q退出）: " folder
        [[ "$folder" =~ ^[qQ]$ ]] && return
        [[ "$folder" != /* ]] && folder="/sdcard/$folder"
        if [ -d "$folder" ]; then
            echo "$folder"
            return 0
        else
            red "❌ 文件夹不存在：$folder"
            read -p "按回车重试..."
        fi
    done
}
# 常规刷机模式（修复语法，全功能保留）
fastboot_flash() {
    while true; do
        clear
        purple "======================"
        purple "  常规刷机模式       "
        purple "======================"
        show_device_status
        
        yellow "🔢 选择 [1-4]（输入q返回）"
        yellow "1. 刷写镜像（.img → 自动分区+确认）"
        yellow "2. 刷写ZIP（.zip → Recovery）"
        yellow "3. 批量刷镜像（自动分区+批量确认）"
        yellow "4. 返回主菜单"
        
        read -r -p "选择: " opt
        [[ "$opt" =~ ^[qQ]$ ]] && break
        case $opt in
            1)  
                img=$(select_file_with_exit "img")  
                if [ -z "$img" ]; then 
                    red "❌ 已取消"
                    continue
                fi
                
                part=$(guess_partition "$img")  
                if [[ -z "$part" ]]; then
                    red "❌ 分区无效"
                    continue
                fi
                
                green "镜像: $(basename "$img") → 分区: $part"
                read -p "确认刷入？(y/n/q) " confirm
                [[ "$confirm" =~ ^[qQ]$ ]] && continue
                [[ "$confirm" != "y" ]] && read -p "新分区: " part
                
                local cmd="fastboot flash $part \"$img\""
                [ -n "$(cat ~/.fastboot_path 2>/dev/null)" ] && 
                    termux-usb -r -e "$cmd" -E "$(cat ~/.fastboot_path)" || 
                    eval "$cmd"
                
                [ $? -eq 0 ] && green "🎉 成功" || red "❌ 失败"
                read -p "回车返回..."
                ;;
            2)  
                zip=$(select_file_with_exit "zip")  
                if [ -z "$zip" ]; then 
                    red "❌ 已取消"
                    continue
                fi
                
                [[ ! $(echo "$zip" | tr '[:upper:]' '[:lower:]') =~ \.zip$ ]] && {
                    red "❌ 仅支持.zip文件"
                    continue
                }
                
                green "ZIP包: $(basename "$zip")"
                yellow "⚠ 需进入Recovery并开启ADB侧载"
                read -p "开始侧载？(y/n/q) " confirm
                [[ "$confirm" =~ ^[qQ]$ ]] && continue
                [[ "$confirm" != "y" ]] && continue
                
                adb sideload "$zip" && green "🎉 成功" || red "❌ 失败"
                read -p "回车返回..."
                ;;
            3)  
                folder=$(select_folder_with_exit)  
                if [ -z "$folder" ]; then 
                    red "❌ 已取消"
                    continue
                fi
                
                local img_files=()
                while IFS= read -r img; do
                    img_files+=("$img")
                done < <(find "$folder" -maxdepth 1 -type f \( -iname "*.img" -o -iname "*.IMG" \) | sort)
                
                [ ${#img_files[@]} -eq 0 ] && {
                    red "❌ 无IMG文件"
                    continue
                }
                
                green "检测到${#img_files[@]}个文件："
                for i in "${!img_files[@]}"; do
                    echo "$((i+1)). $(basename "${img_files[$i]}")"
                done
                
                read -p "全部刷写？(y/n/q) " confirm
                [[ "$confirm" =~ ^[qQ]$ ]] && continue
                
                local saved_path=$(cat ~/.fastboot_path 2>/dev/null)
                local success=0
                
                for img in "${img_files[@]}"; do
                    img_name=$(basename "$img")
                    part=$(guess_partition "$img")
                    [[ -z "$part" ]] && { red "跳过 $img_name（分区无效）"; continue; }
                    
                    green "刷写 $img_name → $part"
                    local cmd="fastboot flash $part \"$img\""
                    [ -n "$saved_path" ] && termux-usb -r -e "$cmd" -E "$saved_path" || eval "$cmd"
                    [ $? -eq 0 ] && ((success++))
                done
                
                green "完成：$success/${#img_files[@]} 成功"
                read -p "回车返回..."
                ;;
            4|q|Q) break ;;
            *) red "无效选项（1-4/q）"; sleep 1 ;;
        esac
    done
}
# 2. 设备控制中心
device_control() {
    while true; do
        clear
        printf "\033[35m%s\033[0m\n" "=================================================="
        printf "\033[35m%30s\033[0m\n" "设备控制中心"
        printf "\033[35m%s\033[0m\n" "=================================================="
        printf "  %-25s  %s\n" "1. ADB查看设备状态"   "2. Fastboot查看设备状态"
        printf "  %-25s  %s\n" "3. ADB重启到系统"     "4. Fastboot重启到系统"
        printf "  %-25s  %s\n" "5. ADB重启到Recovery" "6. Fastboot重启到Recovery"
        printf "  %-25s  %s\n" "7. ADB重启到Fastboot" "8. Fastboot重启到Fastbootd"
        printf "  %-25s  %s\n" "9. 返回主菜单"        " "
        printf "\033[35m%s\033[0m\n" "=================================================="
        read -r -p "  输入数字（1-9）: " num
        if ! [[ "$num" =~ ^[0-9]+$ ]]; then
            red "❌ 必须输入数字！"
            read -p "  按回车重试..."
            continue
        fi
        case "$num" in
            1) 
                green "→ ADB 执行：adb devices + get-state"
                adb devices
                adb get-state
                read -p "  按回车返回..."
                ;;
            3) 
                green "→ ADB 执行：adb reboot"
                adb reboot
                read -p "  命令已发送，按回车返回..."
                ;;
            5) 
                green "→ ADB 执行：adb reboot recovery"
                adb reboot recovery
                read -p "  命令已发送，按回车返回..."
                ;;
            7) 
                green "→ ADB 执行：adb reboot bootloader"
                adb reboot bootloader
                read -p "  命令已发送，按回车返回..."
                ;;
            9) 
                echo "→ 返回主菜单..."
                return
                ;;
            2) 
                green "→ Fastboot 执行：fastboot devices + getvar"
                fastboot devices
                fastboot getvar all
                read -p "  按回车返回..."
                ;;
            4) 
                green "→ Fastboot 执行：fastboot reboot"
                fastboot reboot
                read -p "  命令已发送，按回车返回..."
                ;;
            6) 
                green "→ Fastboot 执行：fastboot reboot recovery"
                fastboot reboot recovery
                read -p "  命令已发送，按回车返回..."
                ;;
            8) 
                green "→ Fastboot 执行：fastboot reboot fastboot"
                fastboot reboot fastboot
                read -p "  命令已发送，按回车返回..."
                ;;
            *) 
                red "❌ 无效数字！请输入1-8（操作）或9（返回）"
                read -p "  按回车重试..."
                ;;
        esac
    done
}
# 3. 自定义命令执行
custom_command() {
    while true; do
        clear
        cyan "======================"
        cyan "  自定义命令执行       "
        cyan "======================"
        yellow "💡 支持adb、fastboot、mtkclient等命令（无视检测结果）"
        yellow "📌 示例：python ~/mtkclient/mtk identify"
        yellow "❓ 输入q返回主菜单"
        cyan "======================"
        read -r -p "请输入命令: " cmd
        if [ "$cmd" = "q" ] || [ "$cmd" = "Q" ]; then
            break  
        elif [ -z "$cmd" ]; then
            red "❌ 命令不能为空！"
            read -r -p "按回车继续..."
        else
            green "▶ 执行：$cmd"
            echo "----------------------"
            eval "$cmd"
            echo "----------------------"
            green "✅ 执行完成"
            read -r -p "按回车继续..."
        fi
    done
}
# 4. 天玑专用刷机（联发科BROM）
mtk_flash() {
    clear
    purple "======================"
    purple "  天玑全自动刷机模式  "
    purple "======================"
    show_device_status
    # 柔性检测
    if [ "${DEVICE_STATE["mtk"]}" != "已检测到" ] && ! confirm_force_exec "联发科BROM"; then
        red "❌ 已取消操作"
        read -p "按回车返回..."
        return 1
    fi
    yellow "💡 流程：选择刷机包 → 自动关机 → 检测BROM → 强制刷写"
    yellow "\n📂 请选择线刷包中的flash_all.sh脚本"
    local script_path=$(select_file_with_exit "sh")  # 补充文件选择函数调用
    if [ -z "$script_path" ]; then
        red "❌ 未选择文件，已取消"
        read -p "按回车返回..."
        return 1
    fi
    if echo "$script_path" | grep -qv "flash_all.sh"; then
        red "❌ 仅支持线刷包的flash_all.sh脚本！"
        read -r -p "按回车返回..."
        return 1
    fi
    green "✅ 已选择刷机脚本：$script_path"
    local adb_available=0
    if [ "${DEVICE_STATE["adb"]}" = "已检测到" ]; then
        adb_available=1
        yellow "🔌 检测到ADB连接，尝试自动关机..."
        adb shell reboot -p >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            green "✅ 已发送ADB关机指令！请等待设备黑屏（约10秒）"
            sleep 10
        else
            red "❌ ADB关机失败！可能原因：设备未ROOT或已进入特殊模式"
            adb_available=0
        fi
    fi
    if [ $adb_available -eq 0 ]; then
        red "❗ 请手动操作：长按电源键10秒强制关机"
        read -r -p "设备已关机并黑屏？按回车继续..."
    fi
    local retries=15
    local found=0
    for ((i=1; i<=retries; i++)); do
        yellow "🔍 第$i次检测BROM模式（剩余$((retries-i+1))次）..."
        if [ -d ~/mtkclient ]; then
            mtk_result=$(python ~/mtkclient/mtk identify 2>/dev/null | grep -i "chip")
            if [ -n "$mtk_result" ]; then
                green "✅ 检测到BROM模式设备："
                echo "$mtk_result" | head -n1
                found=1
                break
            fi
        else
            red "⚠ 未安装mtkclient！请先执行："
            red "git clone https://ghproxy.com/https://github.com/bkerler/mtkclient.git ~/mtkclient"
            red "pip install -r ~/mtkclient/requirements.txt"
            break
        fi
        sleep 3
    done
    if [ $found -eq 0 ]; then
        red "❌ 超时！未检测到BROM模式设备，检查："
        red " 1. 关机后是否长按「音量上+下」并插OTG线"
        red " 2. OTG线是否支持数据传输（非充电线）"
        read -r -p "按回车返回..."
        return 1
    fi
    read -r -p "是否清除数据（会格式化！y/n）: " wipe_data
    if [ "$wipe_data" = "y" ] || [ "$wipe_data" = "Y" ]; then
        yellow "🧹 正在清除数据（metadata/userdata/system）..."
        python ~/mtkclient/mtk e metadata,userdata,system >/dev/null 2>&1
        green "✅ 数据清除完成"
    fi
    yellow "🚀 开始全自动刷写...（过程中请勿拔线）"
    bash "$script_path" && {
        green "🎉 刷机成功！设备将自动重启"
    } || {
        red "❌ 刷机失败！脚本输出："
        bash "$script_path"
        red "手动重试命令：python ~/mtkclient/mtk flashtool $script_path"
    }
    read -r -p "按回车返回..."
}
# 5. 一加手机一键解BL锁
oneplus_unlock_bl() {
    clear
    purple "======================"
    purple "  一加全机型一键解BL"
    purple "======================"
    show_device_status
    # 柔性检测
    if [ "${DEVICE_STATE["adb"]}" != "已检测到" ] && ! confirm_force_exec "ADB（解锁）"; then
        red "❌ 已取消操作"
        read -p "按回车返回..."
        return 1
    fi
    yellow "⚠ 警告：解锁会清除所有数据！请提前备份！"
    yellow "   支持机型：一加全系（含ColorOS系统）"
    read -p "  已备份并确认继续？(y/n): " confirm
    [ "$confirm" != "y" ] && { red "❌ 已取消"; read -p "按回车返回..."; return; }
    yellow "\n📌 步骤1：准备工具"
    if ! command -v adb >/dev/null || ! command -v fastboot >/dev/null; then
        red "❌ 缺少ADB/Fastboot工具！"
        yellow "   正在安装..."
        pkg install -y android-tools || {
            red "❌ 安装失败，请手动执行：pkg install android-tools"
            read -p "按回车返回..."
            return 1
        }
    fi
    green "✅ 工具已就绪"
    yellow "\n📌 步骤2：手机设置"
    echo "   ① 进入 设置 → 关于手机 → 连续点击「版本号」7次，开启开发者模式"
    echo "   ② 返回 设置 → 系统 → 开发者选项，开启："
    echo "      ✅ USB调试"
    echo "      ✅ OEM解锁（重要！）"
    read -p "  已完成设置？(y/n): " setup_confirm
    [ "$setup_confirm" != "y" ] && { red "❌ 请先完成设置"; read -p "按回车返回..."; return; }
    yellow "\n📌 步骤3：连接设备"
    adb kill-server >/dev/null
    echo "   请用原装数据线连接手机，选择「传输文件」模式"
    read -p "  已连接并授权USB调试？(y/n): " conn_confirm
    adb devices | grep -q "device" || {
        red "❌ 未检测到设备！检查："
        red "   ① 数据线 ② USB调试授权 ③ 重新插拔"
        read -p "按回车返回..."
        return 1
    }
    green "✅ ADB连接正常"
    yellow "\n📌 步骤4：进入Fastboot"
    adb reboot bootloader || {
        yellow "⚠ ADB重启失败！请手动进入："
        yellow "   关机后，长按「音量减 + 电源键」直到出现Fastboot界面"
        read -p "  已进入Fastboot？(y/n): " fb_confirm
        [ "$fb_confirm" != "y" ] && { red "❌ 超时未进入"; read -p "按回车返回..."; return; }
    }
    sleep 3
    fastboot devices | grep -q "fastboot" || {
        red "❌ 未检测到Fastboot设备！请重试连接"
        read -p "按回车返回..."
        return 1
    }
    green "✅ 已进入Fastboot模式"
    yellow "\n📌 步骤5：执行解锁（数据清除不可逆）"
    echo -e "\033[31m❗ 手机将显示解锁警告，选择「unlock」并确认！\033[0m"
    read -p "  准备就绪？(y/n): " unlock_confirm
    [ "$unlock_confirm" != "y" ] && { fastboot reboot; read -p "按回车返回..."; return; }
    fastboot oem unlock || fastboot flashing unlock
    if [ $? -eq 0 ]; then
        green "\n🎉 解锁命令已发送！请在手机上操作："
        green "   音量键选择「unlock the bootloader」，电源键确认"
        read -p "  手机已完成解锁并重启？(y/n): " finish_confirm
        [ "$finish_confirm" = "y" ] && green "✅ 解锁成功！设备已恢复出厂设置"
    else
        red "\n❌ 解锁失败！可能原因："
        red "   ① 国内版需申请官方解锁（如一加12及以后）"
        red "   ② 尝试手动命令：fastboot flashing unlock"
        fastboot reboot
    fi
    yellow "\n📌 验证方法："
    yellow "   ① 开机显示黄色解锁警告（5秒）"
    yellow "   ② 关机进入Fastboot，查看最后一行是否为「unlocked」"
    read -p "  按回车返回..."
}
# ==============================================
# 主菜单
# ==============================================
main() {
    fix_storage
    update_fastboot
    while true; do
        clear
        purple "======================"
        purple "  砚风助手（最终版）  "
        purple "======================"
        show_device_status
        yellow "1. 常规刷机（Fastboot/Recovery）"
        yellow "2. 设备控制中心（重启/模式切换）"
        yellow "3. 自定义命令执行"
        yellow "4. 天玑专用刷机（联发科BROM）"
        yellow "5. 一加手机一键解BL锁"
        yellow "6. 退出工具"
        purple "======================"
        read -r -p "🔢 选择功能 [1-6]: " choice
        case $choice in
            1) fastboot_flash ;;
            2) device_control ;;
            3) custom_command ;;
            4) mtk_flash ;;
            5) oneplus_unlock_bl ;;
            6) green "👋 再见！"; exit 0 ;;
            *) red "❌ 无效选项，请输入1-6！"; sleep 1 ;;
        esac
    done
}
# 启动程序
main
