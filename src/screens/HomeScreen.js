import React, { useEffect, useState } from "react";
import { View, Text, StyleSheet, TouchableOpacity, ScrollView, Alert, ActivityIndicator } from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";
import { SafeAreaView } from "react-native-safe-area-context";


import { clearPaired, getPaired } from "../utils/deviceStore";
import { useAuth } from "../context/AuthContext";
import supabase from "../lib/supabase";

function parseDuration(dur) {
  if (!dur) return 0;
  const hours = dur.match(/(\d+)h/) ? parseInt(dur.match(/(\d+)h/)[1]) : 0;
  const mins = dur.match(/(\d+)m/) ? parseInt(dur.match(/(\d+)m/)[1]) : 0;
  return hours * 60 + mins;
}

function formatDuration(totalMins) {
  const h = Math.floor(totalMins / 60);
  const m = totalMins % 60;
  return `${h}h ${m}m`;
}

function getAge(createdAt) {
  const now = new Date();
  const created = new Date(createdAt);
  const diffMs = now - created;
  const diffMins = Math.floor(diffMs / (1000 * 60));
  const diffHours = Math.floor(diffMins / 60);
  const diffDays = Math.floor(diffHours / 24);

  if (diffMins < 60) return `${diffMins}m ago`;
  if (diffHours < 24) return `${diffHours}h ago`;
  return `${diffDays}d ago`;
}

export default function HomeScreen({ navigation }) {
  const { displayName, badge, user } = useAuth();
  const { logout } = useAuth();
  const officerName = `Officer ${displayName}`;
  const badgeText = badge ? `Badge #${badge}` : '';
  const location = "Camarin Rd.";
  const [time, setTime] = useState(new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }));

  
  const [paired, setPaired] = useState(false);
  const [todayCases, setTodayCases] = useState(0);
  const [recordingTime, setRecordingTime] = useState('0h 0m');
  const [emergencies, setEmergencies] = useState(0);
  const [recentActivities, setRecentActivities] = useState([]);
  const [loadingPaired, setLoadingPaired] = useState(true);

  const loadPaired = async () => {
    const p = await getPaired();
    if (!p) {
      navigation.navigate('DevicePairingFlowScreen');
      return;
    }
    setPaired(true);
    setLoadingPaired(false);
  };

  const fetchStats = async () => {
    if (!user?.id) return;

    const activities = [];

    // Today's cases: completed incidents in last 24 hours
    const yesterday = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    const { count: cases } = await supabase
      .from('incidents')
      .select('id', { count: 'exact' })
      .eq('officer_id', user.id)
      .eq('status', 'COMPLETED')
      .gte('created_at', yesterday);
    setTodayCases(cases || 0);

    // Recording time: sum of all durations
    const { data: incs } = await supabase
      .from('incidents')
      .select('duration')
      .eq('officer_id', user.id);
    const totalMins = (incs || []).reduce((sum, i) => sum + parseDuration(i.duration || ''), 0);
    setRecordingTime(formatDuration(totalMins));

    // Emergencies: total emergency triggers
    const { count: ems } = await supabase
      .from('emergency_backups')
      .select('id', { count: 'exact' })
      .eq('auth_user_id', user.id);
    setEmergencies(ems || 0);

    // Recent activities
    // 1. Latest completed incident
    const { data: latestInc } = await supabase
      .from('incidents')
      .select('id, incident_id, violations, created_at')
      .eq('officer_id', user.id)
      .eq('status', 'COMPLETED')
      .order('created_at', { ascending: false })
      .limit(1);
    if (latestInc && latestInc.length > 0) {
      const inc = latestInc[0];
      const firstViolation = inc.violations && inc.violations.length > 0 ? inc.violations[0] : 'Incident';
      const timeAgo = getAge(inc.created_at);
      activities.push({
        main: `${inc.incident_id || inc.id.slice(0, 8)} completed`,
        sub: `${firstViolation} • ${timeAgo}`,
        dotStyle: styles.dotSuccess,
        icon: 'checkmark'
      });
    }

    // 2. Backup requested (temporary hardcoded)
    activities.push({
      main: 'Backup requested',
      sub: 'Camarin Rd. • 1 hour ago',
      dotStyle: styles.dotWarn,
      icon: 'alert'
    });

    // 3. Latest emergency alert sent
    const { data: latestEm } = await supabase
      .from('emergency_backups')
      .select('location, created_at')
      .eq('auth_user_id', user.id)
      .order('created_at', { ascending: false })
      .limit(1);
    if (latestEm && latestEm.length > 0) {
      const em = latestEm[0];
      const timeAgo = getAge(em.created_at);
      activities.push({
        main: 'Emergency alert sent',
        sub: `${em.location || 'Unknown'} • ${timeAgo}`,
        dotStyle: styles.dotDanger,
        icon: 'warning'
      });
    }

    setRecentActivities(activities);
  };

  useEffect(() => {
    loadPaired(); 
    const unsub = navigation.addListener("focus", loadPaired); // refresh when coming back
    return unsub;
  }, [navigation]);

  useEffect(() => {
    const interval = setInterval(() => {
      setTime(new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }));
    }, 60000); // update every minute
    return () => clearInterval(interval);
  }, []);

  useEffect(() => {
    fetchStats();
  }, [user]);

  useEffect(() => {
    const unsub = navigation.addListener("focus", fetchStats); // refetch stats on focus
    return unsub;
  }, [navigation]);

  const handleLogout = () => {
    Alert.alert(
      "Logout",
      "Are you sure you want to logout?",
      [
        {
          text: "Cancel",
          style: "cancel",
        },
        {
          text: "Logout",
          style: "destructive",
          onPress: async () => {
            await logout();
            navigation.reset({ index: 0, routes: [{ name: "Login" }] });
          },
        },
      ]
    );
  };

  const handleStartRecording = () => {
    navigation.navigate("Recording");
  };

  
  const handleDisconnect = async () => {
    await clearPaired();
    setPaired(false);
    navigation.navigate("DeviceWelcome");
  };

  if (loadingPaired) {
    return (
      <LinearGradient
        colors={["#0B1A33", "#3D5F91"]}
        start={{ x: 0.5, y: 0 }}
        end={{ x: 0.5, y: 1 }}
        style={styles.gradient}
      >
        <SafeAreaView style={styles.safe}>
          <View style={{ flex: 1, justifyContent: 'center', alignItems: 'center' }}>
            <ActivityIndicator size="large" color="#2E78E6" />
            <Text style={{ marginTop: 16, color: '#fff', fontSize: 14 }}>
              Loading...
            </Text>
          </View>
        </SafeAreaView>
      </LinearGradient>
    );
  }

  return (
    <LinearGradient
      colors={["#0B1A33", "#3D5F91"]}
      start={{ x: 0.5, y: 0 }}
      end={{ x: 0.5, y: 1 }}
      style={styles.gradient}
    >
      <SafeAreaView style={styles.safe}>
        <ScrollView
          contentContainerStyle={styles.scroll}
          showsVerticalScrollIndicator={false}
          alwaysBounceVertical={false}
        >
          <View style={styles.officerCard}>
            <View style={styles.officerTopRow}>
              <View style={styles.officerLeft}>
                <View style={styles.officerIcon}>
                  <Ionicons name="person" size={18} color="white" />
                </View>

                <View>
                  <Text style={styles.officerName}>{officerName}</Text>
                  <Text style={styles.officerBadge}>{badgeText}</Text>
                </View>
              </View>

              
              <TouchableOpacity onPress={handleLogout} activeOpacity={0.75}>
                <Ionicons name="log-out-outline" size={20} color="#FF4A4A" />
              </TouchableOpacity>
            </View>

            <View style={styles.statusRow}>
              <View style={styles.statusItem}>
                <View style={styles.dotGreen} />
                <Text style={styles.statusText}>On Duty</Text>
              </View>

              <View style={styles.statusItem}>
                <Ionicons name="location-outline" size={14} color="#FF4A4A" />
                <Text style={styles.statusText}>{location}</Text>
              </View>

              <View style={styles.statusItem}>
                <Ionicons name="time-outline" size={14} color="rgba(255,255,255,0.7)" />
                <Text style={styles.statusText}>{time}</Text>
              </View>
            </View>

            
            {paired ? (
              <TouchableOpacity
                style={styles.disconnectBtn}
                activeOpacity={0.85}
                onPress={handleDisconnect}
              >
                <Ionicons
                  name="unlink-outline"
                  size={16}
                  color="rgba(255,255,255,0.85)"
                />
                <Text style={styles.disconnectText}>Disconnect Device</Text>
              </TouchableOpacity>
            ) : null}
          </View>

          <View style={styles.statsRow}>
            <View style={[styles.statCard, styles.statGreenBorder]}>
              <Text style={styles.statValue}>{todayCases}</Text>
              <Text style={styles.statLabel}>Today's Cases</Text>
            </View>

            <View style={[styles.statCard, styles.statYellowBorder]}>
              <Text style={styles.statValue}>{recordingTime}</Text>
              <Text style={styles.statLabel}>Recording Time</Text>
            </View>

            <View style={[styles.statCard, styles.statRedBorder]}>
              <Text style={styles.statValue}>{emergencies}</Text>
              <Text style={styles.statLabel}>Emergencies</Text>
            </View>
          </View>

          <TouchableOpacity
            style={styles.recordCard}
            activeOpacity={0.9}
            onPress={handleStartRecording}
          >
            <View style={styles.recordCircle}>
              <Ionicons name="videocam-outline" size={28} color="#FF1E1E" />
            </View>

            <View style={{ flex: 1 }}>
              <Text style={styles.recordTitle}>Start Recording</Text>
              <Text style={styles.recordSub}>Tap or say "Start Recording"</Text>
            </View>
          </TouchableOpacity>

          <TouchableOpacity
            style={styles.myIncidentCard}
            activeOpacity={0.85}
            onPress={() => navigation.navigate("MyIncident")}
          >
            <View style={styles.myIncidentIconBox}>
              <Ionicons
                name="document-text-outline"
                size={18}
                color="rgba(255,255,255,0.85)"
              />
            </View>
            <Text style={styles.myIncidentTitle}>My Incident</Text>
            <Text style={styles.myIncidentSub}>View History</Text>
          </TouchableOpacity>

          <View style={styles.activityCard}>
            <View style={styles.activityHeader}>
              <Ionicons
                name="hourglass-outline"
                size={18}
                color="rgba(255,255,255,0.75)"
              />
              <Text style={styles.activityTitle}>Recent Activity</Text>
            </View>

            <View style={styles.line} />

            {recentActivities.map((activity, index) => (
              <React.Fragment key={index}>
                <View style={styles.activityItem}>
                  <View style={[styles.activityDot, activity.dotStyle]}>
                    <Ionicons name={activity.icon} size={14} color="white" />
                  </View>
                  <View style={{ flex: 1 }}>
                    <Text style={styles.activityMain}>{activity.main}</Text>
                    <Text style={styles.activitySub}>{activity.sub}</Text>
                  </View>
                </View>
                {index < recentActivities.length - 1 && <View style={styles.itemDivider} />}
              </React.Fragment>
            ))}
          </View>
        </ScrollView>
      </SafeAreaView>
    </LinearGradient>
  );
}

const styles = StyleSheet.create({
  gradient: { flex: 1 },
  safe: { flex: 1 },

  scroll: {
    flexGrow: 1,
    paddingHorizontal: 18,
    paddingTop: 6,
    paddingBottom: 26,
  },

  officerCard: {
    backgroundColor: "rgba(0,0,0,0.20)",
    borderRadius: 12,
    padding: 12,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
  },
  officerTopRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
  },
  officerLeft: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
  },
  officerIcon: {
    width: 34,
    height: 34,
    borderRadius: 10,
    backgroundColor: "#1E7AE6",
    alignItems: "center",
    justifyContent: "center",
  },
  officerName: { color: "white", fontSize: 14, fontWeight: "600" },
  officerBadge: { color: "rgba(255,255,255,0.6)", fontSize: 11, marginTop: 2 },

  statusRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    marginTop: 12,
  },
  statusItem: { flexDirection: "row", alignItems: "center", gap: 6 },
  dotGreen: {
    width: 8,
    height: 8,
    borderRadius: 999,
    backgroundColor: "#3DDC84",
  },
  statusText: { color: "rgba(255,255,255,0.65)", fontSize: 11 },

  disconnectBtn: {
    marginTop: 12,
    height: 40,
    borderRadius: 10,
    backgroundColor: "rgba(255,255,255,0.08)",
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.12)",
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
  },
  disconnectText: { color: "rgba(255,255,255,0.85)", fontSize: 12, fontWeight: "700" },

  statsRow: { flexDirection: "row", gap: 10, marginTop: 12 },
  statCard: {
    flex: 1,
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 12,
    paddingVertical: 12,
    alignItems: "center",
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
  },
  statGreenBorder: { borderColor: "rgba(53, 206, 124, 0.45)" },
  statRedBorder: { borderColor: "rgba(255,80,80,0.40)" },
  statYellowBorder: { borderColor: "rgba(248, 187, 5, 0.4)" },
  statValue: { color: "white", fontSize: 16, fontWeight: "700" },
  statLabel: { color: "rgba(255,255,255,0.55)", fontSize: 11, marginTop: 6 },

  recordCard: {
    marginTop: 15,
    backgroundColor: "#FF1E1E",
    borderRadius: 20,
    paddingHorizontal: 18,
    paddingVertical: 22,
    flexDirection: "row",
    alignItems: "center",
    minHeight: 170,
  },
  recordCircle: {
    width: 65,
    height: 65,
    borderRadius: 999,
    backgroundColor: "white",
    alignItems: "center",
    justifyContent: "center",
    marginRight: 14,
  },
  recordTitle: { color: "white", fontSize: 25, fontWeight: "700" },
  recordSub: { color: "rgba(255,255,255,0.85)", fontSize: 14, marginTop: 6 },

  myIncidentCard: {
    marginTop: 15,
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 14,
    paddingVertical: 18,
    alignItems: "center",
    borderWidth: 1,
    borderColor: "#fab871",
  },
  myIncidentIconBox: {
    width: 40,
    height: 40,
    borderRadius: 10,
    backgroundColor: "rgba(255,255,255,0.08)",
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 8,
  },
  myIncidentTitle: { color: "white", fontSize: 15, fontWeight: "600" },
  myIncidentSub: { color: "rgba(255,255,255,0.55)", fontSize: 11, marginTop: 3 },

  activityCard: {
    marginTop: 10,
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 12,
    padding: 14,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
  },
  activityHeader: { flexDirection: "row", alignItems: "center", gap: 8 },
  activityTitle: { color: "white", fontSize: 14, fontWeight: "600" },
  line: {
    height: 1,
    backgroundColor: "rgba(255,255,255,0.10)",
    marginVertical: 12,
  },

  activityItem: { flexDirection: "row", gap: 10, alignItems: "center" },
  activityDot: {
    width: 24,
    height: 24,
    borderRadius: 9,
    alignItems: "center",
    justifyContent: "center",
  },
  dotSuccess: { backgroundColor: "#2ECC71" },
  dotWarn: { backgroundColor: "#F39C12" },
  dotDanger: { backgroundColor: "#E74C3C" },

  activityMain: { color: "white", fontSize: 13, fontWeight: "600" },
  activitySub: { color: "rgba(255,255,255,0.55)", fontSize: 11, marginTop: 2 },

  itemDivider: {
    height: 1,
    backgroundColor: "rgba(255,255,255,0.08)",
    marginVertical: 10,
  },
});