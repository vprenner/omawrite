#pragma once

#include <QObject>
#include <QVariantList>
#include <QTimer>
#include <memory>

#include "backend.h"

// Each window owns a locked session and each tab owns its document, undo
// history, file watcher and auto-save timer, even while it is in the background.
class Workspace : public QObject {
    Q_OBJECT
    Q_PROPERTY(Backend *activeDocument READ activeDocument NOTIFY activeDocumentChanged)
    Q_PROPERTY(QVariantList tabs READ tabs NOTIFY tabsChanged)
    Q_PROPERTY(int currentIndex READ currentIndex NOTIFY activeDocumentChanged)
public:
    explicit Workspace(QObject *parent = nullptr, const QString &stateDirectory = {});
    ~Workspace() override;
    Backend *activeDocument() const;
    QVariantList tabs() const;
    int currentIndex() const { return m_currentIndex; }
    void setParentWindow(QWindow *window);
    void setDarkMode(bool dark);
    void setDesktopTextScale(qreal scale);
    Q_INVOKABLE void newTab();
    Q_INVOKABLE void openFile(const QUrl &url);
    Q_INVOKABLE void selectTab(int index);
    // The UI asks about unsaved changes before calling this.
    Q_INVOKABLE void closeTab(int index);
    Q_INVOKABLE bool saveSession();
    Q_INVOKABLE void saveViewState(int cursor, qreal scroll);
    Q_INVOKABLE QVariantMap viewState() const;
signals:
    void activeDocumentAboutToChange();
    void activeDocumentChanged();
    void tabsChanged();
    void textScaleChanged();
private:
    struct Tab {
        Backend *backend;
        int cursor = 0;
        qreal scroll = 0;
        bool externalChange = false;
        bool deleted = false;
    };
    Backend *appendTab();
    void synchronizePreferences(Backend *source);
    void scheduleSession();
    void restoreSession();
    void showPendingExternalChange();
    QList<Tab> m_tabs;
    int m_currentIndex = -1;
    QString m_sessionPath;
    std::unique_ptr<QLockFile> m_sessionLock;
    QTimer m_sessionTimer;
    QPointer<QWindow> m_window;
    bool m_darkMode = true;
    qreal m_desktopScale = 1;
    bool m_syncing = false;
    bool m_restoring = true;
};
