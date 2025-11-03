#!/bin/zsh

echo "Which package do you want to check : "
read package

brew=/opt/homebrew/bin/brew
path=/opt/homebrew/bin/$package

if [ -f "$path" ]
then 
    echo "The package exist."
    echo "Path : $path"
    echo "Do you wanna run it(y/n)?"
    read ans

    if [[ $ans == "Y" || $ans == "y" ]]
    then
        $path
    fi
else 
    echo "It doesn't exist. Do you wanna download it(y/n)?"
    read ans

    if [[ $ans == "Y" || $ans == "y" ]]
    then
        $brew install $package
    fi

    echo "Do you wanna run it(y/n)?"
    read ans

    if [[ $ans == "Y" || $ans == "y" ]]
    then
        $path
    fi

fi

echo "Programm exit..."
