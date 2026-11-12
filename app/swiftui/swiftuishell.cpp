// The shell's messages are French templates that the SwiftUI side translates
// (mvHostMessage), so they are not run through tr()
#include "swiftuishell.h"
#include "moonvibeui.h"

#include "backend/boxartmanager.h"
#include "backend/computermanager.h"
#include "backend/nvhttp.h"
#include "settings/streamingpreferences.h"
#include "streaming/awdl.h"
#include "streaming/session.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QThreadPool>
#include <QTimer>
#include <QUrl>

#include <memory>
#include <type_traits>

SwiftUIShell* SwiftUIShell::s_Instance = nullptr;

static QByteArray toJson(const QJsonObject& object)
{
    return QJsonDocument(object).toJson(QJsonDocument::Compact);
}

// An address typed by the user ("host", "host:port", "[ipv6]:port"), read the way
// ComputerManager::addNewHostManually() does. Null when it isn't one.
static NvAddress parseUserAddress(const QString& text)
{
    QString trimmed = text.trimmed();
    QUrl url = QUrl::fromUserInput("moonlight://" + trimmed);
    if (url.isValid() && !url.host().isEmpty() && url.scheme() == "moonlight") {
        return NvAddress(url.host(), url.port(DEFAULT_HTTP_PORT));
    }
    if (QHostAddress(trimmed).protocol() == QAbstractSocket::IPv6Protocol) {
        return NvAddress(trimmed, DEFAULT_HTTP_PORT);
    }
    return NvAddress();
}

SwiftUIShell::SwiftUIShell(ComputerManager* computerManager, QObject* parent)
    : QObject(parent),
      m_ComputerManager(computerManager),
      m_Prefs(StreamingPreferences::get()),
      m_BoxArtManager(new BoxArtManager(this)),
      m_Session(nullptr),
      m_Polling(false)
{
    Q_ASSERT(s_Instance == nullptr);
    s_Instance = this;

    m_BoxArtPushTimer.setSingleShot(true);
    m_BoxArtPushTimer.setInterval(300);
    connect(&m_BoxArtPushTimer, &QTimer::timeout, this, &SwiftUIShell::pushComputers);
    connect(m_BoxArtManager, &BoxArtManager::boxArtLoadComplete, this, [this] {
        m_BoxArtPushTimer.start();
    });

    connect(m_ComputerManager, &ComputerManager::computerStateChanged,
            this, &SwiftUIShell::pushComputers, Qt::QueuedConnection);
    connect(m_ComputerManager, &ComputerManager::pairingCompleted,
            this, &SwiftUIShell::handlePairingCompleted);
    connect(m_ComputerManager, &ComputerManager::computerAddCompleted,
            this, &SwiftUIShell::handleComputerAddCompleted);
    connect(m_ComputerManager, &ComputerManager::quitAppCompleted, this, [this](QVariant error) {
        if (!error.isNull()) {
            setStatus(error.toString(), false, true);
        }
        pushComputers();
    });

    // Like the QML UI: keep polling for 5 minutes after Moonvibe goes to the
    // background, so PCs still show up while the user works elsewhere, then stop
    m_InactivityTimer.setSingleShot(true);
    m_InactivityTimer.setInterval(5 * 60 * 1000);
    connect(&m_InactivityTimer, &QTimer::timeout, this, [this] { setPolling(false); });
    connect(qApp, &QGuiApplication::applicationStateChanged,
            this, &SwiftUIShell::handleApplicationStateChanged);
}

void SwiftUIShell::show()
{
    mv_ui_show(&SwiftUIShell::handleAction);
    pushPrefs();
    pushComputers();
    setPolling(true);
}

void SwiftUIShell::setPolling(bool enabled)
{
    // ComputerManager counts start/stop calls, so keep them balanced
    if (enabled && !m_Polling) {
        m_ComputerManager->startPolling();
    }
    else if (!enabled && m_Polling) {
        m_ComputerManager->stopPollingAsync();
    }
    m_Polling = enabled;
}

void SwiftUIShell::handleApplicationStateChanged(Qt::ApplicationState state)
{
    if (state == Qt::ApplicationActive) {
        m_InactivityTimer.stop();
        // Polling stays off for the whole stream
        if (m_Session == nullptr) {
            setPolling(true);
        }
    }
    else if (m_Polling) {
        m_InactivityTimer.start();
    }
}

void SwiftUIShell::pushComputers()
{
    QJsonArray computers;

    for (NvComputer* computer : m_ComputerManager->getComputers()) {
        QVector<NvApp> appList;
        QJsonObject entry;
        bool reachable;
        {
            QReadLocker lock(&computer->lock);
            if (m_DeletingUuids.contains(computer->uuid)) {
                continue;
            }

            appList = computer->appList;
            bool online = computer->state == NvComputer::CS_ONLINE;
            reachable = online && computer->pairState == NvComputer::PS_PAIRED;
            entry = QJsonObject {
                { "uuid", computer->uuid },
                { "name", computer->name },
                { "online", online },
                // An offline host's pair state is unknown: the certificate pinned
                // at pairing tells whether this Mac can stream from it once awake
                { "paired", online ? computer->pairState == NvComputer::PS_PAIRED : !computer->serverCert.isNull() },
                { "canWake", !computer->macAddress.isEmpty() },
                { "mac", QString::fromLatin1(computer->macAddress.toHex(':').toUpper()) },
                { "runningAppId", computer->currentGameId },
            };

            // Detected addresses first, then the ones added by hand
            QJsonArray addresses;
            auto addAddress = [&](const NvAddress& address, const char* kind) {
                if (!address.isNull()) {
                    addresses.append(QJsonObject {
                        { "address", address.address() },
                        { "port", address.port() },
                        { "kind", kind },
                        { "active", online && address == computer->activeAddress },
                    });
                }
            };
            addAddress(computer->localAddress, "local");
            addAddress(computer->remoteAddress, "remote");
            addAddress(computer->ipv6Address, "ipv6");
            addAddress(computer->manualAddress, "manual");
            for (const NvAddress& address : std::as_const(computer->extraAddresses)) {
                addAddress(address, "manual");
            }
            entry.insert("addresses", addresses);
        }

        // Box art for the poster tiles: the cached file right away, and from a paired PC
        // that's online, a download when there's none or once a session, so a cover just
        // set in Sunshine shows up. Each download ends with another push.
        QJsonArray apps;
        for (NvApp& app : appList) {
            if (app.hidden) {
                continue;
            }
            QJsonObject appEntry {
                { "id", app.id },
                { "name", app.name },
            };
            QUrl boxArt = m_BoxArtManager->cachedBoxArt(computer, app.id);
            QString key = computer->uuid + ':' + QString::number(app.id);
            if (reachable && !m_RefreshedBoxArt.contains(key)) {
                m_RefreshedBoxArt.insert(key);
                m_BoxArtManager->refreshBoxArt(computer, app);
            }
            if (boxArt.isLocalFile()) {
                QFileInfo file(boxArt.toLocalFile());
                appEntry.insert("boxArt", file.filePath());
                // Same path once refreshed: the date tells the shell to load it again
                appEntry.insert("boxArtDate", static_cast<double>(file.lastModified().toMSecsSinceEpoch()));
            }
            apps.append(appEntry);
        }
        entry.insert("apps", apps);
        computers.append(entry);
    }

    mv_ui_update_computers(QJsonDocument(computers).toJson(QJsonDocument::Compact).constData());
}

void SwiftUIShell::pushPrefs()
{
    QJsonObject prefs {
        { "resolutionMode", static_cast<int>(m_Prefs->resolutionMode) },
        { "width", m_Prefs->width },
        { "height", m_Prefs->height },
        { "fps", m_Prefs->fps },
        { "bitrateKbps", m_Prefs->bitrateKbps },
        { "unlockBitrate", m_Prefs->unlockBitrate },
        { "windowMode", static_cast<int>(m_Prefs->windowMode) },
        { "vsync", m_Prefs->enableVsync },
        { "framePacing", m_Prefs->framePacing },
        { "hdr", m_Prefs->enableHdr },
        { "yuv444", m_Prefs->enableYUV444 },
        { "videoCodec", static_cast<int>(m_Prefs->videoCodecConfig) },
        { "videoDecoder", static_cast<int>(m_Prefs->videoDecoderSelection) },
        { "renderer", static_cast<int>(m_Prefs->rendererSelection) },
        { "audioConfig", static_cast<int>(m_Prefs->audioConfig) },
        { "muteHost", !m_Prefs->playAudioOnHost },
        { "muteOnFocusLoss", m_Prefs->muteOnFocusLoss },
        { "absoluteMouse", m_Prefs->absoluteMouseMode },
        { "swapMouseButtons", m_Prefs->swapMouseButtons },
        { "reverseScroll", m_Prefs->reverseScrollDirection },
        { "captureSysKeys", static_cast<int>(m_Prefs->captureSysKeysMode) },
        { "multiController", m_Prefs->multiController },
        { "backgroundGamepad", m_Prefs->backgroundGamepad },
        { "gamepadMouse", m_Prefs->gamepadMouse },
        { "swapFaceButtons", m_Prefs->swapFaceButtons },
        { "mdns", m_Prefs->enableMdns },
        { "detectNetworkBlocking", m_Prefs->detectNetworkBlocking },
        { "disableAwdl", m_Prefs->disableAwdl },
        { "quitAppAfter", m_Prefs->quitAppAfter },
        { "gameOptimizations", m_Prefs->gameOptimizations },
        { "keepAwake", m_Prefs->keepAwake },
        { "showStats", m_Prefs->showPerformanceOverlay },
        { "connectionWarnings", m_Prefs->connectionWarnings },
        { "configurationWarnings", m_Prefs->configurationWarnings },
        { "richPresence", m_Prefs->richPresence },
    };
    mv_ui_update_prefs(toJson(prefs).constData());
}

void SwiftUIShell::applyPrefs(const QJsonObject& prefs)
{
    auto readBool = [&prefs](const char* key, bool& value) { value = prefs[key].toBool(value); };
    auto readInt = [&prefs](const char* key, int& value) { value = prefs[key].toInt(value); };
    auto readEnum = [&prefs](const char* key, auto& value) {
        value = static_cast<std::remove_reference_t<decltype(value)>>(prefs[key].toInt(static_cast<int>(value)));
    };

    readEnum("resolutionMode", m_Prefs->resolutionMode);
    readInt("width", m_Prefs->width);
    readInt("height", m_Prefs->height);
    readInt("fps", m_Prefs->fps);
    readInt("bitrateKbps", m_Prefs->bitrateKbps);
    readBool("unlockBitrate", m_Prefs->unlockBitrate);
    readEnum("windowMode", m_Prefs->windowMode);
    readBool("vsync", m_Prefs->enableVsync);
    readBool("framePacing", m_Prefs->framePacing);
    m_Prefs->framePacing = m_Prefs->framePacing && m_Prefs->enableVsync;
    readBool("hdr", m_Prefs->enableHdr);
    readBool("yuv444", m_Prefs->enableYUV444);
    readEnum("videoCodec", m_Prefs->videoCodecConfig);
    readEnum("videoDecoder", m_Prefs->videoDecoderSelection);
    readEnum("renderer", m_Prefs->rendererSelection);
    readEnum("audioConfig", m_Prefs->audioConfig);
    m_Prefs->playAudioOnHost = !prefs["muteHost"].toBool(!m_Prefs->playAudioOnHost);
    readBool("muteOnFocusLoss", m_Prefs->muteOnFocusLoss);
    readBool("absoluteMouse", m_Prefs->absoluteMouseMode);
    readBool("swapMouseButtons", m_Prefs->swapMouseButtons);
    readBool("reverseScroll", m_Prefs->reverseScrollDirection);
    readEnum("captureSysKeys", m_Prefs->captureSysKeysMode);
    readBool("multiController", m_Prefs->multiController);
    readBool("backgroundGamepad", m_Prefs->backgroundGamepad);
    readBool("gamepadMouse", m_Prefs->gamepadMouse);
    readBool("swapFaceButtons", m_Prefs->swapFaceButtons);
    readBool("mdns", m_Prefs->enableMdns);
    readBool("detectNetworkBlocking", m_Prefs->detectNetworkBlocking);
    readBool("quitAppAfter", m_Prefs->quitAppAfter);
    readBool("gameOptimizations", m_Prefs->gameOptimizations);
    readBool("keepAwake", m_Prefs->keepAwake);
    readBool("showStats", m_Prefs->showPerformanceOverlay);
    readBool("connectionWarnings", m_Prefs->connectionWarnings);
    readBool("configurationWarnings", m_Prefs->configurationWarnings);
    readBool("richPresence", m_Prefs->richPresence);

    // Without an unlocked bitrate, keep it within the standard range
    if (!m_Prefs->unlockBitrate && m_Prefs->bitrateKbps > 150000) {
        m_Prefs->bitrateKbps = 150000;
    }

    // The shell always picks the bitrate explicitly (presets or slider)
    m_Prefs->autoAdjustBitrate = false;

    bool disableAwdl = prefs["disableAwdl"].toBool(m_Prefs->disableAwdl);
    if (disableAwdl && !m_Prefs->disableAwdl && !AwdlBlocker::isControlReady()) {
        // Toggling AWDL needs a one-time admin approval. The option turns on once it's granted.
        disableAwdl = false;
        AwdlBlocker::installSudoersRuleAsync(this, [this](bool ready) {
            if (ready) {
                m_Prefs->disableAwdl = true;
                m_Prefs->save();
            }
            else {
                setStatus(QStringLiteral("Autorisation refusée : l'AWDL reste actif pendant le stream."), false, true);
            }
            pushPrefs();
        });
    }
    m_Prefs->disableAwdl = disableAwdl;

    m_Prefs->save();
    pushPrefs();
}

int SwiftUIShell::streamState()
{
    Session* session = s_Instance->m_Session;
    if (session == nullptr) {
        return 0;
    }

    return (session->isCaptureActive() ? MV_STREAM_CAPTURED : 0) |
           (session->isExternalStatsVisible() ? MV_STREAM_STATS : 0) |
           (session->isStreamFullScreen() ? MV_STREAM_FULLSCREEN : 0);
}

void SwiftUIShell::handleAction(const char* json)
{
    QJsonObject action = QJsonDocument::fromJson(QByteArray(json)).object();

    // Stream overlay actions arrive while Qt's event loop is suspended by the stream,
    // so they can't be queued: hand them straight to the session's event loop
    if (action["action"].toString() == "streamAction") {
        if (s_Instance->m_Session != nullptr) {
            s_Instance->m_Session->requestStreamAction(action["value"].toInt());
        }
        return;
    }

    // Leave the SwiftUI event handler before doing any heavy lifting
    QMetaObject::invokeMethod(s_Instance, [action] {
        s_Instance->dispatch(action);
    }, Qt::QueuedConnection);
}

NvComputer* SwiftUIShell::findComputer(const QString& uuid)
{
    for (NvComputer* computer : m_ComputerManager->getComputers()) {
        QReadLocker lock(&computer->lock);
        if (computer->uuid == uuid) {
            return computer;
        }
    }
    return nullptr;
}

void SwiftUIShell::dispatch(const QJsonObject& action)
{
    QString type = action["action"].toString();

    if (type == "launch") {
        launch(action["uuid"].toString(), action["appId"].toInt(),
               QPoint(action["displayX"].toInt(), action["displayY"].toInt()),
               action["overrides"].toObject());
    }
    else if (type == "cancel") {
        if (m_Session != nullptr) {
            m_Session->interrupt();
        }
    }
    else if (type == "wake") {
        wake(action);
    }
    else if (type == "rename") {
        NvComputer* computer = findComputer(action["uuid"].toString());
        QString name = action["name"].toString().trimmed();
        if (computer != nullptr && !name.isEmpty()) {
            m_ComputerManager->renameHost(computer, name);
        }
    }
    else if (type == "setAddresses") {
        setUserAddresses(action["uuid"].toString(), action["addresses"].toArray());
    }
    else if (type == "testAddress") {
        testAddress(action["uuid"].toString(), action["address"].toString());
    }
    else if (type == "quitApp") {
        NvComputer* computer = findComputer(action["uuid"].toString());
        if (computer != nullptr) {
            m_ComputerManager->quitRunningApp(computer);
        }
    }
    else if (type == "refreshApps") {
        // While an app is being added on the PC, so it shows up within seconds
        NvComputer* computer = findComputer(action["uuid"].toString());
        if (computer != nullptr && computer->state == NvComputer::CS_ONLINE &&
                computer->pairState == NvComputer::PS_PAIRED) {
            m_ComputerManager->refreshAppList(computer);
        }
    }
    else if (type == "pair") {
        pair(action["uuid"].toString());
    }
    else if (type == "deleteHost") {
        deleteHost(action["uuid"].toString());
    }
    else if (type == "addHost") {
        m_ComputerManager->addNewHostManually(action["address"].toString().trimmed());
    }
    else if (type == "setPrefs") {
        applyPrefs(action["prefs"].toObject());
    }
    else if (type == "quit") {
        QCoreApplication::quit();
    }
}

void SwiftUIShell::pair(const QString& computerUuid)
{
    NvComputer* computer = findComputer(computerUuid);
    if (computer == nullptr) {
        return;
    }

    // The PC shows nothing: the user types this PIN into Sunshine
    QString pin = m_ComputerManager->generatePinString();
    mv_ui_update_pairing(toJson(QJsonObject {
        { "uuid", computerUuid },
        { "stage", "waiting" },
        { "pin", pin },
    }).constData());
    m_ComputerManager->pairHost(computer, pin);
}

void SwiftUIShell::wake(const QJsonObject& action)
{
    QString computerUuid = action["uuid"].toString();
    NvComputer* computer = findComputer(computerUuid);
    if (computer == nullptr) {
        return;
    }

    // The shell's own wake options: a MAC address typed by the user ("AA:BB:CC:DD:EE:FF",
    // fromHex() skips the separators) and an extra target outside the local network
    QByteArray macOverride = QByteArray::fromHex(action["mac"].toString().toLatin1());
    if (macOverride.size() != 6) {
        macOverride.clear();
    }
    QString extraAddress = action["address"].toString().trimmed();
    int extraPort = action["port"].toInt();
    if (extraPort <= 0 || extraPort > 65535) {
        extraAddress.clear();
        extraPort = 0;
    }

    // Resolving host names can block, so the packets go out from a worker thread,
    // using a copy of the host that a deletion can't pull from under it
    NvComputer snapshot;
    {
        QReadLocker lock(&computer->lock);
        snapshot = *computer;
    }
    QThreadPool::globalInstance()->start([this, snapshot, computerUuid, macOverride, extraAddress, extraPort] {
        bool sent = snapshot.wake(macOverride, extraAddress, static_cast<quint16>(extraPort));
        QMetaObject::invokeMethod(this, [computerUuid, sent] {
            mv_ui_wake_result(toJson(QJsonObject {
                { "uuid", computerUuid },
                { "sent", sent },
            }).constData());
        }, Qt::QueuedConnection);
    });
}

void SwiftUIShell::setUserAddresses(const QString& computerUuid, const QJsonArray& texts)
{
    NvComputer* computer = findComputer(computerUuid);
    if (computer == nullptr) {
        return;
    }

    QVector<NvAddress> addresses;
    for (const QJsonValue& text : texts) {
        NvAddress address = parseUserAddress(text.toString());
        if (!address.isNull() && !addresses.contains(address)) {
            addresses.append(address);
        }
    }
    m_ComputerManager->setUserAddresses(computer, addresses);
}

void SwiftUIShell::testAddress(const QString& computerUuid, const QString& text)
{
    auto report = [computerUuid, text](const QString& result) {
        mv_ui_address_test_result(toJson(QJsonObject {
            { "uuid", computerUuid },
            { "address", text },
            { "result", result },
        }).constData());
    };

    NvComputer* computer = findComputer(computerUuid);
    NvAddress address = parseUserAddress(text);
    if (computer == nullptr || address.isNull()) {
        report(QStringLiteral("invalid"));
        return;
    }

    QSslCertificate serverCert;
    bool useTrueUid;
    {
        QReadLocker lock(&computer->lock);
        serverCert = computer->serverCert;
        useTrueUid = !computer->isNvidiaServerSoftware;
    }

    // Same check as polling: the address must answer, and with this PC's ID
    QThreadPool::globalInstance()->start([this, computerUuid, address, serverCert, useTrueUid, report] {
        QString result;
        try {
            NvHTTP http(address, 0, serverCert, useTrueUid);
            QString serverInfo = http.getServerInfo(NvHTTP::NVLL_NONE, true);
            result = NvHTTP::getXmlString(serverInfo, "uniqueid").compare(computerUuid, Qt::CaseInsensitive) == 0
                    ? QStringLiteral("ok") : QStringLiteral("other");
        } catch (...) {
            result = QStringLiteral("unreachable");
        }
        QMetaObject::invokeMethod(this, [report, result] { report(result); }, Qt::QueuedConnection);
    });
}

void SwiftUIShell::deleteHost(const QString& computerUuid)
{
    NvComputer* computer = findComputer(computerUuid);
    if (computer == nullptr) {
        return;
    }

    // Deletion finishes on a worker thread: hide the host meanwhile, then let
    // discovery bring it back as a new, unpaired PC if it is still on the network
    m_DeletingUuids.insert(computerUuid);
    m_ComputerManager->deleteHost(computer);
    pushComputers();

    QTimer::singleShot(1500, this, [this, computerUuid] {
        m_DeletingUuids.remove(computerUuid);
        pushComputers();
    });
}

void SwiftUIShell::handlePairingCompleted(NvComputer* computer, QString error)
{
    QString uuid;
    {
        QReadLocker lock(&computer->lock);
        uuid = computer->uuid;
    }

    mv_ui_update_pairing(toJson(QJsonObject {
        { "uuid", uuid },
        { "stage", error.isEmpty() ? "paired" : "failed" },
        { "error", error },
    }).constData());
    pushComputers();
}

void SwiftUIShell::handleComputerAddCompleted(QVariant success, QVariant detectedPortBlocking)
{
    mv_ui_add_host_result(toJson(QJsonObject {
        { "success", success.toBool() },
        { "portBlocking", detectedPortBlocking.toBool() },
    }).constData());
    pushComputers();
}

void SwiftUIShell::setStatus(const QString& text, bool busy, bool error, bool cancellable, const QStringList& args)
{
    QJsonObject status {
        { "text", text },
        { "busy", busy },
        { "error", error },
        { "cancellable", cancellable },
        { "args", QJsonArray::fromStringList(args) },
    };
    mv_ui_set_status(toJson(status).constData());
}

void SwiftUIShell::launch(const QString& computerUuid, int appId, const QPoint& displayOrigin, const QJsonObject& overrides)
{
    // The previous session is still cleaning up, for a few seconds at most
    if (m_Session != nullptr) {
        setStatus(QStringLiteral("Le stream précédent se termine, réessaie dans un instant."), false);
        return;
    }

    NvComputer* computer = findComputer(computerUuid);
    NvApp app;
    // The address the stream goes through, for its report: LAN, VPN or the Internet
    QString streamAddress;
    if (computer != nullptr) {
        QReadLocker lock(&computer->lock);
        for (const NvApp& candidate : computer->appList) {
            if (candidate.id == appId) {
                app = candidate;
                break;
            }
        }
        streamAddress = computer->activeAddress.address();
    }

    if (computer == nullptr || !app.isInitialized()) {
        setStatus(QStringLiteral("Cette app n'est plus disponible."), false, true);
        return;
    }

    m_LaunchError.clear();
    m_LaunchErrorArgs.clear();

    // An app with its own quality streams with a copy of the preferences, adjusted for
    // this stream only: the saved preferences don't change, even if Moonvibe quits mid-stream
    StreamingPreferences* prefs = m_Prefs;
    if (!overrides.isEmpty()) {
        prefs = StreamingPreferences::createDetached();
        prefs->resolutionMode = static_cast<StreamingPreferences::ResolutionMode>(
                    overrides["resolutionMode"].toInt(static_cast<int>(prefs->resolutionMode)));
        prefs->width = overrides["width"].toInt(prefs->width);
        prefs->height = overrides["height"].toInt(prefs->height);
        prefs->fps = overrides["fps"].toInt(prefs->fps);
        prefs->bitrateKbps = overrides["bitrateKbps"].toInt(prefs->bitrateKbps);
    }

    m_Session = new Session(computer, app, prefs);
    if (prefs != m_Prefs) {
        prefs->setParent(m_Session);
    }
    m_Session->setDisplayOrigin(displayOrigin);
    m_Session->setExternalOverlayUi(true);

    // Stream overlays: these signals fire on the streaming and decoder threads
    // while Qt's event loop is suspended, hence the direct connections
    QByteArray overlayInfo = toJson(QJsonObject {
        { "computer", computer->name },
        { "app", app.name },
        { "targetMbps", prefs->bitrateKbps / 1000.0 },
    });
    connect(m_Session, &Session::streamWindowReady, this, [overlayInfo](void* nativeWindow) {
        mv_overlay_begin(nativeWindow, overlayInfo.constData(), &SwiftUIShell::streamState);
    }, Qt::DirectConnection);
    connect(m_Session, &Session::statsUpdated, this, [](Session::StreamStats stats) {
        mv_overlay_stats(toJson(QJsonObject {
            { "fps", stats.fps },
            { "width", stats.width },
            { "height", stats.height },
            { "bitrateMbps", stats.bitrateMbps },
            { "rttMs", static_cast<int>(stats.rttMs) },
            { "decodeMs", stats.decodeMs },
            { "dropPercent", stats.dropPercent },
        }).constData());
    }, Qt::DirectConnection);
    connect(m_Session, &Session::streamWindowClosing, this, [] {
        mv_overlay_end();
    }, Qt::DirectConnection);

    connect(m_Session, &Session::stageStarting, this, [this](QString stage) {
        setStatus(QStringLiteral("Démarrage : %1…"), true, false, true, { stage });
    });
    connect(m_Session, &Session::stageFailed, this, [this](QString stage, int errorCode, QString failingPorts) {
        if (failingPorts.isEmpty()) {
            m_LaunchError = QStringLiteral("Échec au démarrage de %1 (erreur %2).");
            m_LaunchErrorArgs = { stage, QString::number(errorCode) };
        }
        else {
            m_LaunchError = QStringLiteral("Échec au démarrage de %1 (erreur %2).\n\nVérifie ton pare-feu et la redirection des ports : %3");
            m_LaunchErrorArgs = { stage, QString::number(errorCode), failingPorts };
        }
    });
    connect(m_Session, &Session::displayLaunchError, this, [this](QString text) {
        // Session's own errors, already translated by Qt
        m_LaunchError = text;
        m_LaunchErrorArgs.clear();
    });
    connect(m_Session, &Session::connectionStarted, this, [] {
        mv_ui_set_visible(false);
    });
    // Brings Home back once, when the stream window goes away. With "quit the app after
    // streaming", that's before the session checks the PC and asks it to quit the app:
    // Home shows the quit in progress meanwhile.
    auto restoreHome = [restored = std::make_shared<bool>(false)] {
        if (*restored) {
            return;
        }
        *restored = true;
        mv_ui_set_visible(true);
    };
    QString appName = app.name;
    connect(m_Session, &Session::quitStarting, this, [this, restoreHome, appName] {
        restoreHome();
        // A new stream can't start until the quit is over, and it can't be cancelled
        setStatus(QStringLiteral("%1 se ferme sur le PC…"), true, false, false, { appName });
    });
    connect(m_Session, &Session::sessionFinished, this, [this, restoreHome, computerUuid, appName, streamAddress](int) {
        restoreHome();
        setStatus(m_LaunchError, false, !m_LaunchError.isEmpty(), true, m_LaunchErrorArgs);

        Session::StreamReport report = m_Session->streamReport();
        if (report.durationSecs > 0) {
            mv_ui_stream_report(toJson(QJsonObject {
                { "computerId", computerUuid },
                { "app", appName },
                { "address", streamAddress },
                { "durationSecs", report.durationSecs },
                { "width", report.width },
                { "height", report.height },
                { "targetFps", report.targetFps },
                { "codec", report.codec },
                { "receivedFps", report.receivedFps },
                { "renderedFps", report.renderedFps },
                { "networkDropPercent", report.networkDropPercent },
                { "jitterDropPercent", report.jitterDropPercent },
                { "rttMs", static_cast<int>(report.rttMs) },
                { "rttVarianceMs", static_cast<int>(report.rttVarianceMs) },
                { "decodeMs", report.decodeMs },
                { "audioCuts", report.audioQueueOverflows },
            }).constData());
        }
    });
    connect(m_Session, &Session::readyForDeletion, this, [this] {
        m_Session->deleteLater();
        m_Session = nullptr;
        // Polling resumes once the session has checked the PC is still there,
        // so it starts from the right state instead of overwriting it
        setPolling(true);
        if (qApp->applicationState() != Qt::ApplicationActive) {
            m_InactivityTimer.start();
        }
        pushComputers();
    });

    setStatus(QStringLiteral("Démarrage : %1…"), true, false, true, { app.name });

    if (!m_Session->initialize(nullptr)) {
        if (m_LaunchError.isEmpty()) {
            setStatus(QStringLiteral("Impossible de préparer le stream."), false, true);
        }
        else {
            setStatus(m_LaunchError, false, true, true, m_LaunchErrorArgs);
        }
        m_Session->deleteLater();
        m_Session = nullptr;
        return;
    }

    // Polling hits the PC every few seconds over the network the stream needs
    setPolling(false);
    m_InactivityTimer.stop();

    QTimer::singleShot(0, m_Session, &Session::start);
}
