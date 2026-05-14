## FAN SPEED
fan() {
    echo "Tawan's fan control"
    validArg=0
    fanLevel=''
    case "$1" in
        "auto" | "full-speed" | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | "disengaged")
            fanLevel=$1
            validArg=1
            ;;
        "full" | "max")
            fanLevel="full-speed"
            validArg=1
            ;;
        "check")
            validArg=2
            ;;
        *)
            validArg=0
            ;;
    esac

    if [ $validArg == 1 ]; then
        echo "Setting fan level = $fanLevel"
        if [[ "$fanLevel" == "auto" ]]; then
            ## Switch to auto: ensure thinkfan is running
            if systemctl is-active --quiet thinkfan; then
                echo "thinkfan already running — no change needed."
            else
                echo "Starting thinkfan service..."
                sudo systemctl start thinkfan
            fi
        else
            ## Switch to manual: ensure thinkfan is stopped before writing level
            if systemctl is-active --quiet thinkfan; then
                echo "Stopping thinkfan service..."
                sudo systemctl stop thinkfan
            else
                echo "thinkfan already stopped — no change needed."
            fi
            ## ThinkPad specific path
            echo "level $fanLevel" | sudo tee /proc/acpi/ibm/fan
        fi
    elif [ $validArg == 2 ]; then
        echo "Temp: /proc/acpi/ibm/thermal"
        cat /proc/acpi/ibm/thermal
        echo "Fan: /proc/acpi/ibm/fan"
        cat /proc/acpi/ibm/fan
    else
        echo "Invalid argument: fanLevel: \"$1\", expected [auto|full|0-7|disengaged|full-speed|max]"
        echo "In case check, use \"fan check\""
    fi
}
