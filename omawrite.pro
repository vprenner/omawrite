QT += core gui concurrent widgets printsupport qml quick quickcontrols2 quickdialogs2 dbus

CONFIG += c++17 release
TARGET = omawritev
TEMPLATE = app

HEADERS += \
    src/workspace.h \
    src/backend.h \
    src/cli.h \
    src/markdownhighlighter.h \
    src/systemtheme.h

SOURCES += \
    src/workspace.cpp \
    src/main.cpp \
    src/backend.cpp \
    src/cli.cpp \
    src/markdownhighlighter.cpp \
    src/systemtheme.cpp

RESOURCES += src/resources.qrc
