#!/bin/zsh

finished=0

while [ $finished -ne 1 ]
do
    echo "What do you want?"
    echo "1. Chocolet"
    echo "2. Sweet"
    echo "3. Pen"
    echo "4. Paper"
    echo "5. Exit"

    echo "Choose: "
    read ch

    case $ch in
        1) echo "Chocolet Price: 10";;
        2) echo "Sweet Price: 20";;
        3) echo "Pen Price: 5";;
        4) echo "Paper Price: 15";;
        5) finished=1 ;;
        *) echo "Wrong option"
    esac

done

echo "Thanks for using our system"

