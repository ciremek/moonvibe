#pragma once

#include "nvhttp.h"
#include "nvaddress.h"

#include <QThread>
#include <QReadWriteLock>
#include <QSettings>
#include <QRunnable>

class CopySafeReadWriteLock : public QReadWriteLock
{
public:
    CopySafeReadWriteLock() = default;

    // Don't actually copy the QReadWriteLock
    CopySafeReadWriteLock(const CopySafeReadWriteLock&) : QReadWriteLock() {}
    CopySafeReadWriteLock& operator=(const CopySafeReadWriteLock &) { return *this; }
};

class NvComputer
{
    friend class PcMonitorThread;
    friend class ComputerManager;
    friend class PendingQuitTask;
    friend class AppListRefreshTask;

private:
    void sortAppList();

    bool updateAppList(QVector<NvApp> newAppList);

    bool pendingQuit;

public:
    NvComputer() = default;

    // Caller is responsible for synchronizing read access to the other host
    NvComputer(const NvComputer&) = default;

    // Caller is responsible for synchronizing read access to the other host
    NvComputer& operator=(const NvComputer &) = default;

    explicit NvComputer(NvHTTP& http, QString serverInfo);

    explicit NvComputer(QSettings& settings);

    void
    setRemoteAddress(QHostAddress);

    bool
    update(const NvComputer& that);

    // macOverride replaces the MAC address reported by the host, and extraAddress:extraPort
    // is one more target, such as a DDNS name whose port the router forwards to the host
    bool
    wake(const QByteArray& macOverride = QByteArray(),
         const QString& extraAddress = QString(), quint16 extraPort = 0) const;

    enum ReachabilityType
    {
        RI_UNKNOWN,
        RI_LAN,
        RI_VPN,
    };

    ReachabilityType
    getActiveAddressReachability() const;

    QVector<NvAddress>
    uniqueAddresses() const;

    // Whether an IP address belongs to a network this machine is directly on,
    // which excludes the point-to-point tunnels of VPNs like Tailscale
    static bool
    isOnLocalNetwork(const QString& address);

    void
    serialize(QSettings& settings, bool serializeApps) const;

    // Caller is responsible for synchronizing read access to both hosts
    bool
    isEqualSerialized(const NvComputer& that) const;

    enum PairState
    {
        PS_UNKNOWN,
        PS_PAIRED,
        PS_NOT_PAIRED
    };

    enum ComputerState
    {
        CS_UNKNOWN,
        CS_ONLINE,
        CS_OFFLINE
    };

    // Ephemeral traits
    ComputerState state;
    PairState pairState;
    NvAddress activeAddress;
    uint16_t activeHttpsPort;
    int currentGameId;
    QString gfeVersion;
    QString appVersion;
    QVector<NvDisplayMode> displayModes;
    int maxLumaPixelsHEVC;
    int serverCodecModeSupport;
    QString gpuModel;
    bool isSupportedServerVersion;

    // Persisted traits
    NvAddress localAddress;
    NvAddress remoteAddress;
    NvAddress ipv6Address;
    NvAddress manualAddress;
    // Further addresses added by hand (another VPN, say); polling tries them after the others
    QVector<NvAddress> extraAddresses;
    QByteArray macAddress;
    QString name;
    bool hasCustomName;
    QString uuid;
    QSslCertificate serverCert;
    QVector<NvApp> appList;
    bool isNvidiaServerSoftware;
    // Remember to update isEqualSerialized() when adding fields here!

    // Synchronization
    mutable CopySafeReadWriteLock lock;

private:
    uint16_t externalPort;
};
