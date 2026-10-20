#include "workspace.h"

#include <QDir>
#include <QDateTime>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLockFile>
#include <QSaveFile>
#include <QStandardPaths>
#include <QTextDocument>
#include <QWindow>

static QString fileIdentity(const QUrl &url);

Workspace::Workspace(QObject *parent, const QString &stateDirectory) : QObject(parent) {
    const QString directory = stateDirectory.isEmpty()
        ? QStandardPaths::writableLocation(QStandardPaths::AppDataLocation) + "/sessions"
        : stateDirectory;
    QDir().mkpath(directory);
    QFile::setPermissions(directory, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
    // Recover an unlocked previous window before allocating a new session.
    // Separate running windows must never overwrite one another's drafts.
    for (int pass = 0; pass < 2 && !m_sessionLock; ++pass) {
        for (int slot = 0; slot < 1000; ++slot) {
            const QString base = QDir(directory).filePath(QStringLiteral("window-%1").arg(slot));
            if ((pass == 0) != QFileInfo::exists(base + ".json"))
                continue;
            auto lock = std::make_unique<QLockFile>(base + ".lock");
            if (lock->tryLock()) {
                m_sessionPath = base + ".json";
                m_sessionLock = std::move(lock);
                break;
            }
        }
    }
    m_sessionTimer.setSingleShot(true);
    m_sessionTimer.setInterval(300);
    connect(&m_sessionTimer, &QTimer::timeout, this, &Workspace::saveSession);
    restoreSession();
    if (m_tabs.isEmpty()) {
        // Import an upstream crash-recovery draft when no tab session exists.
        Backend *document = appendTab();
        if (stateDirectory.isEmpty()) {
            Backend legacy(nullptr);
            auto *text = new QTextDocument(&legacy);
            legacy.initializeDocument(text);
            legacy.restoreRecovery();
            if (legacy.modified()) {
                document->loadDocumentText(legacy.currentDocumentText());
                document->setFileUrl(legacy.fileUrl());
                document->setKnownFileContents(legacy.m_lastKnownFileContents, legacy.m_hasKnownFileContents);
                document->suspendAutoSave();
                document->setModified(true);
                document->watchCurrentFile();
                document->setStatus(QStringLiteral("Recovered unsaved changes"));
                // Only remove the old recovery after the new session is durable.
                m_currentIndex = 0;
                m_restoring = false;
                if (saveSession())
                    legacy.clearRecovery();
            }
        }
    }
    if (m_currentIndex < 0 || m_currentIndex >= m_tabs.size())
        m_currentIndex = 0;
    m_restoring = false;
    saveSession();
}

Workspace::~Workspace() {
    m_sessionTimer.stop();
    saveSession();
    // Delete backends while the session lock is still held.
    for (const Tab &tab : m_tabs)
        delete tab.backend;
}

Backend *Workspace::activeDocument() const {
    return m_currentIndex >= 0 && m_currentIndex < m_tabs.size()
        ? m_tabs.at(m_currentIndex).backend : nullptr;
}

QVariantList Workspace::tabs() const {
    QVariantList result;
    for (const Tab &tab : m_tabs)
        result.append(QVariantMap{{"name", tab.backend->fileName()},
                                  {"path", tab.backend->fileUrl().toLocalFile()},
                                  {"modified", tab.backend->modified()},
                                  {"externalChange", tab.externalChange}});
    return result;
}

Backend *Workspace::appendTab() {
    auto *document = new Backend(this, false);
    document->initializeDocument(new QTextDocument(document));
    document->setParentWindow(m_window);
    document->setDarkMode(m_darkMode);
    document->setDesktopTextScale(m_desktopScale);
    m_tabs.append({document});
    document->m_saveAllowed = [this, document](const QUrl &url) {
        if (!url.isLocalFile()) return true; // Backend reports the invalid URL.
        for (const Tab &tab : m_tabs)
            if (tab.backend != document && tab.backend->fileUrl().isLocalFile()
                && fileIdentity(tab.backend->fileUrl()) == fileIdentity(url))
                return false;
        return true;
    };
    connect(document, &Backend::documentEdited, this, &Workspace::scheduleSession);
    connect(document, &Backend::fileUrlChanged, this, [this] { emit tabsChanged(); scheduleSession(); });
    connect(document, &Backend::modifiedChanged, this, [this] { emit tabsChanged(); scheduleSession(); });
    connect(document, &Backend::saveSucceeded, this, &Workspace::scheduleSession);
    // Reloading text may leave modified=false, so persist that operation too.
    connect(document, &Backend::statusChanged, this, &Workspace::scheduleSession);
    const auto preferencesChanged = [this, document] { synchronizePreferences(document); };
    connect(document, &Backend::autoSaveEnabledChanged, this, preferencesChanged);
    connect(document, &Backend::widthModeChanged, this, preferencesChanged);
    connect(document, &Backend::editorFontChanged, this, preferencesChanged);
    connect(document, &Backend::textScaleChanged, this, preferencesChanged);
    connect(document, &Backend::externalChangeDetected, this, [this, document](bool deleted, bool) {
        for (Tab &tab : m_tabs) {
            if (tab.backend == document) {
                tab.externalChange = true;
                tab.deleted = deleted;
            }
        }
        emit tabsChanged();
    });
    connect(document, &Backend::saveSucceeded, this, [this, document] {
        for (Tab &tab : m_tabs)
            if (tab.backend == document) tab.externalChange = false;
        emit tabsChanged();
    });
    connect(document, &Backend::externalChangeResolved, this, [this, document] {
        for (Tab &tab : m_tabs)
            if (tab.backend == document) tab.externalChange = false;
        emit tabsChanged();
    });
    return document;
}

void Workspace::synchronizePreferences(Backend *source) {
    if (m_syncing) return;
    m_syncing = true;
    for (const Tab &tab : m_tabs) {
        Backend *target = tab.backend;
        if (target == source) continue;
        target->setAutoSaveEnabled(source->autoSaveEnabled());
        target->setWidthMode(source->widthMode());
        target->setEditorFont(source->editorFont());
        if (!qFuzzyCompare(target->m_textZoom, source->m_textZoom))
            target->setTextZoom(source->m_textZoom);
    }
    m_syncing = false;
    emit textScaleChanged();
}

void Workspace::setParentWindow(QWindow *window) {
    m_window = window;
    for (const Tab &tab : m_tabs) tab.backend->setParentWindow(window);
}

void Workspace::setDarkMode(bool dark) {
    m_darkMode = dark;
    for (const Tab &tab : m_tabs) tab.backend->setDarkMode(dark);
}

void Workspace::setDesktopTextScale(qreal scale) {
    m_desktopScale = scale;
    for (const Tab &tab : m_tabs) tab.backend->setDesktopTextScale(scale);
}

void Workspace::newTab() {
    appendTab();
    emit tabsChanged();
    selectTab(m_tabs.size() - 1);
}

static QString fileIdentity(const QUrl &url) {
    const QFileInfo info(url.toLocalFile());
    return info.exists() ? info.canonicalFilePath() : info.absoluteFilePath();
}

void Workspace::openFile(const QUrl &url) {
    if (!url.isLocalFile()) {
        activeDocument()->setStatus(QStringLiteral("Only local files can be opened."));
        return;
    }
    for (int i = 0; i < m_tabs.size(); ++i) {
        if (m_tabs.at(i).backend->fileUrl().isLocalFile()
            && fileIdentity(m_tabs.at(i).backend->fileUrl()) == fileIdentity(url)) {
            selectTab(i);
            return;
        }
    }
    // An untouched placeholder can become the first opened file.
    Backend *document = activeDocument();
    const bool reuse = document && document->fileUrl().isEmpty() && !document->modified()
        && document->currentDocumentText().isEmpty();
    if (!reuse) document = appendTab();
    document->openOrStartFile(url);
    emit tabsChanged();
    if (!reuse) selectTab(m_tabs.size() - 1);
    saveSession();
}

void Workspace::selectTab(int index) {
    if (index < 0 || index >= m_tabs.size() || index == m_currentIndex) return;
    emit activeDocumentAboutToChange();
    m_currentIndex = index;
    emit activeDocumentChanged();
    saveSession();
    showPendingExternalChange();
}

void Workspace::showPendingExternalChange() {
    // Background tabs keep watching files. Present their conflict on activation.
    Tab &tab = m_tabs[m_currentIndex];
    if (tab.externalChange) {
        emit tab.backend->externalChangeDetected(tab.deleted, tab.backend->modified());
    }
}

void Workspace::closeTab(int index) {
    if (index < 0 || index >= m_tabs.size()) return;
    emit activeDocumentAboutToChange();
    Backend *removed = m_tabs.takeAt(index).backend;
    if (m_tabs.isEmpty()) appendTab();
    if (index < m_currentIndex) --m_currentIndex;
    else if (index == m_currentIndex) m_currentIndex = qMin(index, int(m_tabs.size()) - 1);
    emit tabsChanged();
    emit activeDocumentChanged();
    // The view has now detached from this document.
    removed->deleteLater();
    saveSession();
    showPendingExternalChange();
}

void Workspace::saveViewState(int cursor, qreal scroll) {
    if (!activeDocument()) return;
    m_tabs[m_currentIndex].cursor = cursor;
    m_tabs[m_currentIndex].scroll = scroll;
    scheduleSession();
}

QVariantMap Workspace::viewState() const {
    if (!activeDocument()) return {};
    const Tab &tab = m_tabs.at(m_currentIndex);
    return {{"cursor", tab.cursor}, {"scroll", tab.scroll}};
}

void Workspace::scheduleSession() {
    if (!m_restoring) m_sessionTimer.start();
}

bool Workspace::saveSession() {
    if (m_restoring) return true;
    m_sessionTimer.stop();
    QJsonArray tabs;
    for (const Tab &tab : m_tabs) {
        tabs.append(QJsonObject{{"url", tab.backend->fileUrl().toString()},
                                {"text", tab.backend->currentDocumentText()},
                                {"modified", tab.backend->modified()},
                                {"cursor", tab.cursor}, {"scroll", tab.scroll}});
    }
    QSaveFile file(m_sessionPath);
    bool success = m_sessionLock && file.open(QIODevice::WriteOnly);
    if (success) {
        file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        const QByteArray json = QJsonDocument(QJsonObject{{"version", 1}, {"active", m_currentIndex},
                                                         {"tabs", tabs}}).toJson(QJsonDocument::Compact);
        success = file.write(json) == json.size() && file.commit();
    }
    if (!success && activeDocument())
        activeDocument()->setStatus(QStringLiteral("Could not save the tab session. Save your work before closing."));
    return success;
}

void Workspace::restoreSession() {
    QFile file(m_sessionPath);
    if (!file.open(QIODevice::ReadOnly)) return;
    const QJsonDocument json = QJsonDocument::fromJson(file.readAll());
    if (!json.isObject() || json.object().value("version").toInt() != 1
        || !json.object().value("tabs").isArray()) {
        // Preserve unreadable state for manual recovery, never overwrite it.
        file.close();
        file.rename(m_sessionPath + ".unreadable-" + QString::number(QDateTime::currentMSecsSinceEpoch()));
        return;
    }
    for (const QJsonValue &value : json.object().value("tabs").toArray()) {
        if (!value.isObject()) continue;
        const QJsonObject entry = value.toObject();
        Backend *document = appendTab();
        const QUrl url(entry.value("url").toString());
        if (url.isLocalFile()) document->openOrStartFile(url);
        // Reopen clean files from disk; retain snapshots for dirty, missing or
        // unreadable files. Restored edits always wait for an explicit save.
        const bool snapshot = entry.value("modified").toBool()
            || (url.isLocalFile() && !document->m_hasKnownFileContents);
        if (snapshot || url.isEmpty()) {
            document->loadDocumentText(entry.value("text").toString());
            document->setFileUrl(url);
            document->setModified(snapshot || !document->currentDocumentText().isEmpty());
            if (document->modified()) {
                document->suspendAutoSave();
                document->setStatus(QStringLiteral("Restored unsaved changes; save to keep them."));
            }
        }
        m_tabs.last().cursor = entry.value("cursor").toInt();
        m_tabs.last().scroll = entry.value("scroll").toDouble();
    }
    m_currentIndex = json.object().value("active").toInt();
}
