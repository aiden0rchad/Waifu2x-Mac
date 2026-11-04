#ifndef PLATFORM_H
#define PLATFORM_H

#include <QCoreApplication>
#include <QDir>
#include <QStandardPaths>
#include <QString>

/*
 * Platform abstraction for the macOS port.
 * Engine binaries are named "<engine>_waifu2xEX" plus W2X_EXE_SUFFIX.
 */

#ifdef Q_OS_WIN
#define W2X_EXE_SUFFIX ".exe"
#else
#define W2X_EXE_SUFFIX ""
#endif

inline QString W2xDataPath()
{
    const QString overridePath=qEnvironmentVariable("W2X_DATA_DIR");
    if(!overridePath.isEmpty()){QDir().mkpath(overridePath);return overridePath;}
#ifdef Q_OS_MACOS
    QString path = QDir::homePath() + "/Library/Application Support/Waifu2xMacGUI";
    QDir().mkpath(path);
    return path;
#else
    return QCoreApplication::applicationDirPath();
#endif
}

#endif // PLATFORM_H
