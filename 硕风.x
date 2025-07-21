#!/data/data/com.termux/files/usr/bin/bash
# 砚风工具箱2.0（修复版）
echo -e "\033[33m🚀 正在安装核心工具（android-tools/termux-api/sudo）...\033[0m"
if ! pkg install -y android-tools termux-api sudo; then
    echo -e "\033[31m❌ 核心工具安装失败！请手动执行：\033[0m"
    echo -e "\033[31mpkg install -y android-tools termux-api sudo\033[0m"
    exit 1
fi
# 彩色输出增强
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
cyan() { echo -e "\033[36m$1\033[0m"; }
purple() { echo -e "\033[35m$1\033[0m"; }
# 修复存储路径兼容
fix_storage() {
    if [ ! -L /sdcard ]; then
        ln -s /storage/emulated/0 /sdcard 2>/dev/null
    fi
}
# 修复依赖检查
fix_deps() {
    yellow "🚀 部署环境..."
    local deps=("android-tools" "termux-api" "unzip" "python" "git" "libusb")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            yellow "📦 安装 $dep..."
            pkg install -y "$dep" || {
                red "❌ $dep安装失败！手动修复：pkg install -y $dep"
                exit 1
            }
        fi
    done
    pkg install -y android-tools termux-api sudo
    if [ ! -d ~/mtkclient ]; then
        yellow "ℹ️ 联发科工具未安装（不影响其他功能），如需使用："
        yellow "手动执行：git clone https://ghproxy.com/https://github.com/bkerler/mtkclient.git ~/mtkclient"
        yellow "再执行：pip install -r ~/mtkclient/requirements.txt"
    fi
    green "✅ 环境就绪！"
}
# 自动更新fastboot工具
update_fastboot() {
    yellow "🔧 检测fastboot版本..."
    if ! fastboot --help | grep -q "fastbootd"; then
        yellow "📥 发现旧版本，正在更新至最新版..."
        local temp_zip=$(mktemp).zip
        if curl -sSL "https://dl.google.com/android/repository/platform-tools-latest-linux.zip" -o "$temp_zip"; then
            local temp_dir=$(mktemp -d)
            unzip -q "$temp_zip" -d "$temp_dir"
            cp "$temp_dir/platform-tools/fastboot" "$PREFIX/bin/"
            chmod +x "$PREFIX/bin/fastboot"
            rm -rf "$temp_zip" "$temp_dir"
            green "✅ fastboot已更新至最新版（支持Fastbootd）"
        else
            red "❌ 下载失败！请手动执行："
            red "wget https://dl.google.com/android/repository/platform-tools-latest-linux.zip -O /sdcard/platform-tools.zip"
            red "unzip /sdcard/platform-tools.zip -d ~/ && cp ~/platform-tools/fastboot ~/../usr/bin/"
        fi
    else
        green "✅ fastboot版本兼容（已支持Fastbootd）"
    fi
}
# 智能文件选择
select_file() {
    if command -v termux-file-editor >/dev/null 2>&1; then
        local temp=$(mktemp)
        termux-file-editor "$temp" >/dev/null 2>&1
        local path=$(cat "$temp" 2>/dev/null)
        rm -f "$temp"
        path=$(echo "$path" | sed -e "s|/storage/emulated/0|/sdcard|g" -e "s|/mnt/sdcard|/sdcard|g")
        if [ -f "$path" ] && echo "$path" | grep -q "\.img$\|\.zip$\|\.sh$"; then
            echo "$path"
            return 0
        else
            yellow "⚠ 请选择.img（镜像）、.zip（刷机包）或.sh（脚本）"
        fi
    fi
    yellow "📌 请输入文件路径（示例：/sdcard/flash_all.sh）"
    while true; do
        read -r -p "📂 路径: " path
        [[ "$path" != /sdcard/* && "$path" != /* ]] && path="/sdcard/$path"
        path=$(echo "$path" | sed -e "s|/storage/emulated/0|/sdcard|g" -e "s|/mnt/sdcard|/sdcard|g")
        if [ -f "$path" ]; then
            if echo "$path" | grep -q "\.img$\|\.zip$\|\.sh$"; then
                echo "$path"
                return 0
            else
                red "❌ 仅支持.img、.zip或.sh文件！"
            fi
        else
            red "❌ 路径无效，请重新输入"
        fi
    done
}
# 分区智能识别
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
# 联发科专属刷机模式
mtk_flash() {
    clear
    purple "======================"
    purple "  天玑全自动刷机模式  "
    purple "======================"
    yellow "💡 流程：选择刷机包 → 自动关机 → 检测BROM → 强制刷写"
    yellow "   支持ADB自动关机，失败则引导手动操作"
    yellow "\n📂 请选择线刷包中的flash_all.sh脚本"
    local script_path=$(select_file)
    if echo "$script_path" | grep -qv "flash_all.sh"; then
        red "❌ 仅支持线刷包的flash_all.sh脚本！"
        read -r -p "按回车返回..."
        return 1
    fi
    green "✅ 已选择刷机脚本：$script_path"
    local adb_available=0
    if check_device; then
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
# 设备控制中心
function device_control() {
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
# 常规刷机模式
fastboot_flash() {
    while true; do
        clear
        purple "======================"
        purple "  常规刷机模式       "
        purple "======================"
        yellow "1. 刷写镜像文件（.img → Fastboot）"
        yellow "2. 刷写ZIP包（.zip → Recovery）"
        yellow "3. 批量刷写镜像（文件夹 → Fastbootd）"
        yellow "4. 返回主菜单"
        purple "======================"
        read -r -p "🔢 选择 [1-4]: " opt
        case $opt in
            1)  
                img=$(select_file)
                if echo "$img" | grep -qv "\.img$"; then
                    red "❌ Fastboot模式仅支持 .img 文件！"
                    read -r -p "按回车返回..."
                    continue
                fi
                part=$(guess_partition "$img")
                green "✅ 镜像路径: $img"
                green "💡 自动识别分区：$part（回车确认，或输入新分区）"
                read -r -p "📌 分区名: " input_part
                part=${input_part:-$part}
                local saved_path=$(cat ~/.fastboot_path 2>/dev/null)
                if [ -n "$saved_path" ]; then
                    yellow "🔗 使用已绑定的设备路径：$saved_path"
                    termux-usb -r -e "fastboot flash $part $img" -E "$saved_path" && green "🎉 刷写成功！" || red "❌ 刷写失败！"
                else
                    if ! check_device; then
                        read -r -p "按回车返回..."
                        continue
                    fi
                    fastboot flash "$part" "$img" && green "🎉 刷写成功！" || {
                        red "❌ 刷写失败！检查分区名或设备连接"
                    }
                fi
                read -r -p "按回车返回..."
                ;;
            2)  
                zip=$(select_file)
                if echo "$zip" | grep -qv "\.zip$"; then
                    red "❌ Recovery模式仅支持 .zip 文件！"
                    read -r -p "按回车返回..."
                    continue
                fi
                green "✅ ZIP包路径: $zip"
                if ! check_device; then
                    read -r -p "按回车返回..."
                    continue
                fi
                adb sideload "$zip" && green "🎉 刷写成功！" || red "❌ 刷写失败！请确认设备在Recovery模式"
                read -r -p "按回车返回..."
                ;;
            3)  
                yellow "📂 请选择存放镜像的文件夹（仅支持.img文件）"
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
                        read -r -p "文件夹路径: " folder_input
                        [[ "$folder_input" != /sdcard/* && "$folder_input" != /* ]] && folder_input="/sdcard/$folder_input"
                        if [ -d "$folder_input" ]; then
                            folder="$folder_input"
                            break
                        else
                            red "❌ 无效文件夹！"
                        fi
                    done
                fi
                local img_files=$(find "$folder" -maxdepth 1 -type f -name "*.img" | sort)
                if [ -z "$img_files" ]; then
                    red "❌ 文件夹内无.img文件！"
                    read -r -p "按回车返回..."
                    continue
                fi
                green "✅ 检测到以下镜像："
                echo "$img_files" | while read -r img; do echo "  - $(basename "$img")"; done
                yellow "⚠ 请确保设备已进入Fastbootd模式！"
                read -r -p "确认刷写？（y/n）: " confirm
                if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                    yellow "⚠ 已取消"
                    read -r -p "按回车返回..."
                    continue
                fi
                local saved_path=$(cat ~/.fastboot_path 2>/dev/null)
                if [ -n "$saved_path" ]; 
                then
                yellow "🔗 使用已绑定的设备路径：$saved_path"
                    local total=$(echo "$img_files" | wc -l)
                    local count=1
                    green "🚀 开始通过已绑定路径批量刷写（共$total个文件）..."
                    echo "$img_files" | while read -r img; do
                        local img_name=$(basename "$img")
                        local part=$(guess_partition "$img")
                        if [ "$part" = "无法识别，请手动输入" ]; then
                            yellow "\n⚠ $img_name 分区未知"
                            while true; do
                                read -r -p "请输入分区名: " input_part
                                [ -n "$input_part" ] && { part="$input_part"; break; } || red "❌ 分区名不能为空！"
                            done
                        fi
                        green "\n===== 刷写第$count/$total个：$img_name（分区：$part） ====="
                        termux-usb -r -e "fastboot flash $part $img" -E "$saved_path"
                        if [ $? -eq 0 ]; then
                            green "✅ 刷写成功"
                        else
                            red "❌ 刷写失败，可尝试手动执行：fastboot flash $part $img"
                        fi
                        ((count++))
                    done
                else
                    if ! fastboot devices | grep -q "fastboot"; then
                        red "❌ 未检测到 Fastbootd 设备！请先进入 Fastbootd 模式"
                        read -r -p "按回车返回..."
                        continue
                    fi
                    local total=$(echo "$img_files" | wc -l)
                    local count=1
                    green "🚀 开始直接批量刷写（共$total个文件）..."
                    echo "$img_files" | while read -r img; do
                        local img_name=$(basename "$img")
                        local part=$(guess_partition "$img")
                        if [ "$part" = "无法识别，请手动输入" ]; then
                            yellow "\n⚠ $img_name 分区未知"
                            while true; do
                                read -r -p "请输入分区名: " input_part
                                [ -n "$input_part" ] && { part="$input_part"; break; } || red "❌ 分区名不能为空！"
                            done
                        fi
                        green "\n===== 刷写第$count/$total个：$img_name（分区：$part） ====="
                        fastboot flash "$part" "$img"
                        if [ $? -eq 0 ]; then
                            green "✅ 刷写成功"
                        else
                            red "❌ 刷写失败，检查设备连接或分区名"
                        fi
                        ((count++))
                    done
                fi
                green "\n📊 批量刷写流程结束！"
                red "⚠ 若有失败项，建议单独排查处理"
                read -r -p "按回车返回上级菜单..."
                ;;
            4) break ;;
            *) red "❌ 无效选项！"; sleep 1 ;;
        esac
    done
}
# 自定义命令执行
custom_command() {
    while true; do
        clear
        cyan "======================"
        cyan "  自定义命令执行       "
        cyan "======================"
        yellow "💡 支持adb、fastboot、mtkclient等命令"
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
# 设备检测
check_device() {
    local retries=3
    local delay=2
    local adb_dev=""
    local fb_dev=""
    local mtk_dev=""
    local saved_path=$(cat ~/.fastboot_path 2>/dev/null)
    for ((i=1; i<=retries; i++)); do
        adb_dev=$(adb devices | grep -v "List" | grep -v "^$")
        if [ -n "$saved_path" ]; then
            fb_dev=$(termux-usb -r -e "fastboot devices" -E "$saved_path" 2>/dev/null | grep -v "^$")
        else
            fb_dev=$(fastboot devices | grep -v "^$")
        fi
        if [ -d ~/mtkclient ]; then
            mtk_dev=$(python ~/mtkclient/mtk identify 2>/dev/null | grep "Chip")
        fi
        if [ -n "$adb_dev" ] || [ -n "$fb_dev" ] || [ -n "$mtk_dev" ]; then
            break
        fi
        if [ $i -lt $retries ]; then
            yellow "🔍 重试检测设备（$i/$retries）..."
            sleep $delay
        fi
    done
    if [ -n "$adb_dev" ]; then
        green "✅ ADB设备已连接"
        return 0
    elif [ -n "$fb_dev" ]; then
        green "✅ Fastboot设备已连接"
        return 0
    elif [ -n "$mtk_dev" ]; then
        green "✅ 联发科BROM设备已连接"
        return 0
    else
        red "❌ 未检测到设备！"
        red " 1. 开启USB调试  2. 联发科设备长按音量上+下+插线"
        return 1
    fi
}
# 一加手机一键解BL模块
function oneplus_unlock_bl() {
    clear
    purple "======================"
    purple "  一加全机型一键解BL"
    purple "======================"
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
# 新增：Fastboot识别修复工具
fix_fastboot_recognition() {
    clear
    purple "======================"
    purple "  Fastboot识别修复工具  "
    purple "======================"
    yellow "💡 解决：fastboot devices无响应/设备未列出问题"
    yellow "   使用前请在设置打开USB和OTG后重启到fastboot"
    purple "======================"

    yellow "\n📌 步骤1：检查fastboot环境"
    if ! command -v fastboot >/dev/null; then
        red "❌ fastboot未安装！正在修复..."
        pkg install -y android-tools || {
            red "❌ 安装失败，请手动执行：pkg install -y android-tools"
            read -r -p "按回车返回..."
            return 1
        }
    fi
    green "✅ fastboot已安装"
    update_fastboot

    yellow "\n📌 步骤2：USB权限与路径绑定"
    yellow "   请确保设备已进入Fastboot模式（长按电源键+音量下）"
    read -r -p "设备已进入Fastboot？(y/n): " fb_confirm
    [ "$fb_confirm" != "y" ] && { red "❌ 请先进入Fastboot模式"; read -r -p "按回车返回..."; return 1; }

    yellow "\n   检测USB设备列表..."
    if ! command -v termux-usb >/dev/null; then
        red "❌ 缺少termux-usb工具！正在安装..."
        pkg install -y termux-api || {
            red "❌ 安装失败，请手动执行：pkg install -y termux-api"
            read -r -p "按回车返回..."
            return 1
        }
    fi
    usb_devices=$(termux-usb -l)
    if [ -z "$usb_devices" ]; then
        red "❌ 未检测到任何USB设备！检查："
        red "   1. OTG线是否支持数据传输（非充电线）"
        red "   2. 设备是否正确进入Fastboot模式（屏幕显示fastboot标识）"
        red "   3. 重新插拔USB线，更换接口"
        read -r -p "按回车重试..."
        fix_fastboot_recognition
        return 0
    fi

    green "✅ 检测到USB设备："
    echo "$usb_devices" | nl
    read -r -p "📌 输入设备编号（如1）: " usb_num
    usb_path=$(echo "$usb_devices" | sed -n "${usb_num}p")
    if [ -z "$usb_path" ]; then
        red "❌ 无效编号！"
        read -r -p "按回车返回..."
        return 1
    fi

    yellow "\n   绑定设备路径：$usb_path"
    termux-usb -r -e "fastboot devices" -E "$usb_path" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        red "❌ 权限授予失败！手动执行："
        red "termux-usb -r -e \$SHELL -E $usb_path"
        read -r -p "授予权限后按回车继续..."
    fi

    yellow "\n   测试识别：fastboot devices"
    green "----------------------"
    termux-usb -r -e "fastboot devices" -E "$usb_path"
    green "----------------------"
    read -r -p "是否看到设备ID？(y/n): " recognized
    if [ "$recognized" = "y" ] || [ "$recognized" = "Y" ]; then
        echo "$usb_path" > ~/.fastboot_path
        green "✅ 识别成功！已保存设备路径（下次自动生效）"
    else
        red "❌ 仍未识别！尝试进阶修复..."
        yellow "\n📌 进阶修复方案："
        echo "1. 确认设备已解锁Bootloader（设置→开发者选项→OEM解锁）"
        echo "2. 更换原装Type-C线（非充电线，支持数据传输）"
        echo "3. 重启设备：fastboot reboot bootloader（重新进入模式）"
        echo "4. 更新fastboot：执行脚本中的「环境部署」功能"
    fi
    read -r -p "按回车返回..."
}
# 主菜单（已整合新增功能）
main() {
    fix_storage
    fix_deps
    update_fastboot
    while true; do
        clear
        purple "======================"
        purple "  砚风助手2.0       "
        purple "======================"
        yellow "1. 常规刷机（Fastboot/Recovery）"
        yellow "2. 设备控制中心（重启/模式切换）"
        yellow "3. 自定义命令执行"
        yellow "4. 天玑专用刷机（联发科BROM）"
        yellow "5. 一加手机一键解BL锁"
        yellow "6. Fastboot识别修复工具"  # 新增功能
        yellow "7. 退出工具"  # 原有退出项顺延
        purple "======================"
        read -r -p "🔢 选择功能 [1-7]: " choice
        case $choice in
            1) fastboot_flash ;;
            2) device_control ;;
            3) custom_command ;;
            4) mtk_flash ;;
            5) oneplus_unlock_bl ;;
            6) fix_fastboot_recognition ;;  # 调用新增功能
            7) green "👋 再见！"; exit 0 ;;
            *) red "❌ 无效选项，请输入1-7！"; sleep 1 ;;
        esac
    done
}
main
