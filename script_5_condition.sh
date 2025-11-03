#!/bin/zsh

echo "Which package do you wanna check : "
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
        $brew install $package >> package_installation_result.log
    else
        echo "Program exit.."
        exit 1
    fi

    if [ $? -eq 0 ] 
    then

        echo "Do you wanna run it(y/n)?"
        read ans

        if [[ $ans == "Y" || $ans == "y" ]]
        then
            $path
        fi
    else
        echo "The package doesn't exist"
    fi

fi

echo "Programm exit..."
