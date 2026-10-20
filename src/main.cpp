#include <QFont>
#include <QFontDatabase>
#include <QApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlError>
#include <QQuickStyle>
#include <QUrl>
#include <QWindow>
#include <QFile>
#include <QDir>
#include <QSettings>
#include <QStandardPaths>
#include <QTemporaryDir>

#include "backend.h"
#include "cli.h"
#include "systemtheme.h"
#include "workspace.h"

#define OMAWRITE_VERSION "0.7.2"

// The first fork build shared upstream's identity. Copy its tab sessions into
// the new namespace once, without moving or modifying the previous state.
static bool importPreviousForkState() {
    const QDir data(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation));
    const QString destination = data.filePath(QStringLiteral("sessions"));
    const QDir previous(QDir::cleanPath(data.filePath(QStringLiteral("../omawrite/sessions"))));
    const QStringList snapshots = previous.entryList({QStringLiteral("window-*.json")}, QDir::Files);
    if (!QFileInfo::exists(destination) && !snapshots.isEmpty()) {
        if (!QDir().mkpath(data.path())) return false;
        QTemporaryDir staging(data.filePath(QStringLiteral(".sessions-XXXXXX")));
        if (!staging.isValid()) return false;
        for (const QString &name : snapshots) {
            const QString target = staging.filePath(name);
            if (!QFile::copy(previous.filePath(name), target)) return false;
            QFile::setPermissions(target, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        }
        if (!QDir().rename(staging.path(), destination)) return false;
        staging.setAutoRemove(false);
    }
    QSettings settings;
    if (settings.allKeys().isEmpty()) {
        const QSettings previousSettings(QStringLiteral("Omacom"), QStringLiteral("omawrite"));
        for (const QString &key : previousSettings.allKeys())
            settings.setValue(key, previousSettings.value(key));
    }
    return true;
}

int main(int argc, char *argv[]) {
    // Answered before the application exists, so they need no display.
    if (const std::optional<int> exitCode =
            Cli::handleArguments(argc, argv, QStringLiteral(OMAWRITE_VERSION)))
        return *exitCode;

    // Omarchy asks Qt for GTK 3 dialogs, which run inside this process, and a
    // long-standing GTK 3 file chooser assertion aborts the whole app, unsaved
    // text and all. The desktop portal shows the same chooser from a process
    // of its own.
    if (qgetenv("QT_QPA_PLATFORMTHEME") == "gtk3")
        qputenv("QT_QPA_PLATFORMTHEME", "xdgdesktopportal");

    // Set the identity before Qt initializes its platform/portal integration.
    QCoreApplication::setApplicationName(QStringLiteral("omawritev"));
    QCoreApplication::setApplicationVersion(QStringLiteral(OMAWRITE_VERSION));
    QCoreApplication::setOrganizationName(QStringLiteral("Omacom"));
    QCoreApplication::setOrganizationDomain(QStringLiteral("omacom.io"));
    QGuiApplication::setDesktopFileName(QStringLiteral("omawritev"));
    QApplication app(argc, argv);
    app.setApplicationDisplayName(QStringLiteral("OmawriteV"));
    app.setWindowIcon(QIcon::fromTheme(QStringLiteral("omawritev")));

    QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/IBMPlexMono-Regular.ttf"));
    QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/IBMPlexMono-Italic.ttf"));
    QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/IBMPlexMono-Bold.ttf"));
    QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/IBMPlexMono-BoldItalic.ttf"));
    QQuickStyle::setStyle(QStringLiteral("Material"));

    if (!importPreviousForkState()) {
        qCritical() << "Could not copy previous tab sessions into OmawriteV; the original sessions are intact.";
        return 1;
    }
    Workspace workspace(&app);
    SystemTheme systemTheme(&app);
    workspace.setDarkMode(systemTheme.darkMode());
    QObject::connect(&systemTheme, &SystemTheme::darkModeChanged, &workspace,
                     &Workspace::setDarkMode);

    // Carry the text scale into the default font, so the chrome that inherits
    // it (dialog titles, buttons) grows along with the writing area.
    const QFont interfaceFont(QStringLiteral("IBM Plex Mono"));
    const qreal basePointSize = interfaceFont.pointSizeF() > 0
        ? interfaceFont.pointSizeF()
        : app.font().pointSizeF();
    const auto applyInterfaceFont = [&app, interfaceFont, basePointSize](qreal textScale) {
        QFont scaled = interfaceFont;
        scaled.setPointSizeF(basePointSize * textScale);
        app.setFont(scaled);
    };

    // The desktop sets the baseline; the backend folds the user's own text
    // size into it and reports the total.
    workspace.setDesktopTextScale(systemTheme.textScale());
    applyInterfaceFont(workspace.activeDocument()->textScale());
    QObject::connect(&systemTheme, &SystemTheme::textScaleChanged, &workspace,
                     &Workspace::setDesktopTextScale);
    QObject::connect(&workspace, &Workspace::textScaleChanged, &app,
                     [&workspace, applyInterfaceFont]() {
        applyInterfaceFont(workspace.activeDocument()->textScale());
    });

    const QStringList args = app.arguments();
    for (int index = 1; index < args.size(); ++index)
        workspace.openFile(QUrl::fromLocalFile(args.at(index)));

    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::warnings, &app,
                     [](const QList<QQmlError> &warnings) {
        for (const QQmlError &warning : warnings)
            qWarning().noquote() << warning.toString();
    });
    engine.rootContext()->setContextProperty(QStringLiteral("session"), &workspace);

    engine.load(QUrl(QStringLiteral("qrc:/Main.qml")));
    if (engine.rootObjects().isEmpty()) {
        qCritical() << "Could not load the OmawriteV interface; resource available:"
                    << QFile::exists(QStringLiteral(":/Main.qml"));
        return -1;
    }

    workspace.setParentWindow(qobject_cast<QWindow *>(engine.rootObjects().constFirst()));
    QObject::connect(&workspace, &Workspace::activeDocumentChanged, &app, [&workspace, applyInterfaceFont] {
        applyInterfaceFont(workspace.activeDocument()->textScale());
    });

    return app.exec();
}
