#!/bin/zsh

chech_even() {
    n=100
    if [(( $n % 2 )) -eq 0 ]
    then
        echo "Even"
    else 
        echo "Odd"
    fi

}

chech_even

