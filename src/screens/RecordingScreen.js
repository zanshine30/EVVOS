import React, { useEffect, useMemo, useState } from "react";
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  ScrollView,
  Modal,
  Pressable,
} from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";
import { SafeAreaView } from "react-native-safe-area-context";

export default function RecordingScreen({ navigation }) {
  const [seconds, setSeconds] = useState(5);

  // ✅ modals
  const [emergencyOpen, setEmergencyOpen] = useState(false);
  const [stopOpen, setStopOpen] = useState(false);

  useEffect(() => {
    const t = setInterval(() => setSeconds((s) => s + 1), 1000);
    return () => clearInterval(t);
  }, []);

  const timeText = useMemo(() => {
    const mm = String(Math.floor(seconds / 60)).padStart(2, "0");
    const ss = String(seconds % 60).padStart(2, "0");
    return `${mm}:${ss}`;
  }, [seconds]);

  const handleSnapshot = () => console.log("Snapshot (simulation)");
  const handleMark = () => console.log("Mark (simulation)");

  // ✅ Emergency popup (open)
  const handleEmergency = () => setEmergencyOpen(true);

  // ✅ Stop popup (open)
  const handleStop = () => setStopOpen(true);

  // ✅ Confirm Emergency
  const confirmEmergency = () => {
    console.log("Emergency Backup CONFIRMED (simulation)");
    setEmergencyOpen(false);
  };

  // ✅ Confirm Stop -> go IncidentSummary
  const confirmStop = () => {
    console.log("Stop Recording CONFIRMED (simulation)");
    setStopOpen(false);

    // go to IncidentSummary (no GO_BACK issues)
    navigation.navigate("IncidentSummary");
  };

  const bars = useMemo(
    () => [
      12, 22, 16, 28, 14, 26, 18, 30, 16, 24, 14, 28, 18, 26, 16, 22, 14, 28,
    ],
    []
  );

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
          {/* Top title (no back button) */}
          <View style={styles.topHeader}>
            <Text style={styles.headerTitle}>Enforcer Dashboard</Text>
          </View>

          {/* Info row (3 equal columns) */}
          <View style={styles.infoRow}>
            <View style={[styles.infoCol, styles.infoLeft]}>
              <Text style={styles.infoText}>ID: 4521</Text>
            </View>

            <View style={[styles.infoCol, styles.infoCenter]}>
              <View style={styles.infoStatus}>
                <View style={styles.dotGreen} />
                <Text style={styles.infoText}>Active</Text>
              </View>
            </View>

            <View style={[styles.infoCol, styles.infoRight]}>
              <View style={styles.infoLoc}>
                <Ionicons name="location-outline" size={14} color="#FF4A4A" />
                <Text style={[styles.infoText, { marginLeft: 6 }]}>
                  Camarin Rd.
                </Text>
              </View>
            </View>
          </View>

          {/* Divider under info row */}
          <View style={styles.divider} />

          {/* Big Recording Button */}
          <View style={styles.recordWrap}>
            <View style={styles.recordOuter}>
              <View style={styles.recordInner}>
                <View style={styles.stopSquare} />
                <Text style={styles.recTimer}>REC {timeText}</Text>
                <Text style={styles.recText}>RECORDING</Text>
              </View>
            </View>
          </View>

          {/* Waveform row */}
          <View style={styles.waveRow}>
            <View style={styles.micIcon}>
              <Ionicons name="mic" size={18} color="#17F39A" />
            </View>

            <View style={styles.waveBars}>
              {bars.map((h, idx) => (
                <View key={idx} style={[styles.bar, { height: h }]} />
              ))}
            </View>
          </View>

          {/* Live Transcript */}
          <View style={styles.transcriptCard}>
            <View style={styles.transcriptHeader}>
              <View style={styles.transLeft}>
                <Ionicons name="radio-outline" size={16} color="#17F39A" />
                <Text style={styles.transTitle}>Live Transcript</Text>
              </View>

              <View style={styles.listeningWrap}>
                <View style={styles.dotGreenSmall} />
                <Text style={styles.listeningText}>Listening</Text>
              </View>
            </View>

            <View style={styles.transBody}>
              <Text style={styles.transText}>
                Suspect vehicle license plate is Delta X-Ray Charlie 492.
                Proceeding with caution...
              </Text>
            </View>
          </View>

          {/* Snapshot */}
          <TouchableOpacity
            style={styles.snapshotBtn}
            activeOpacity={0.85}
            onPress={handleSnapshot}
          >
            <View style={styles.snapshotIconBox}>
              <Ionicons name="camera" size={18} color="#FFB020" />
            </View>
            <Text style={styles.snapshotText}>Snapshot</Text>
          </TouchableOpacity>

          {/* Emergency Backup */}
          <TouchableOpacity
            style={styles.emergencyBtn}
            activeOpacity={0.9}
            onPress={handleEmergency}
          >
            <Ionicons name="warning-outline" size={16} color="white" />
            <Text style={styles.emergencyText}>Emergency Backup</Text>
          </TouchableOpacity>

          {/* Bottom controls */}
          <View style={styles.bottomRow}>
            <TouchableOpacity
              style={styles.markBtn}
              activeOpacity={0.9}
              onPress={handleMark}
            >
              <Ionicons name="flag-outline" size={16} color="white" />
              <Text style={styles.bottomBtnText}>Mark</Text>
            </TouchableOpacity>

            <TouchableOpacity
              style={styles.stopBtn}
              activeOpacity={0.9}
              onPress={handleStop}
            >
              <Ionicons
                name="stop-circle-outline"
                size={18}
                color="rgba(255,255,255,0.9)"
              />
              <Text style={styles.bottomBtnText}>Stop</Text>
            </TouchableOpacity>
          </View>

          {/* ===================== */}
          {/* ✅ EMERGENCY MODAL */}
          {/* ===================== */}
          <Modal
            visible={emergencyOpen}
            transparent
            animationType="fade"
            onRequestClose={() => setEmergencyOpen(false)}
          >
            <Pressable
              style={styles.modalBackdrop}
              onPress={() => setEmergencyOpen(false)}
            >
              <Pressable style={[styles.modalCard, styles.modalRedBorder]} onPress={() => {}}>
                <View style={styles.modalHeaderRow}>
                  <View style={styles.modalHeaderLeft}>
                    <Ionicons name="warning-outline" size={18} color="#FF4A4A" />
                    <Text style={styles.modalTitle}>Emergency Backup</Text>
                  </View>
                </View>

                <Text style={styles.modalBodyText}>
                  This will send an immediate alert to all nearby units and
                  supervision. Confirm you need emergency assistance.
                </Text>

                <View style={styles.modalBtnRow}>
                  <TouchableOpacity
                    style={[styles.modalBtn, styles.modalBtnCancel]}
                    activeOpacity={0.9}
                    onPress={() => setEmergencyOpen(false)}
                  >
                    <Text style={styles.modalBtnCancelText}>Cancel</Text>
                  </TouchableOpacity>

                  <TouchableOpacity
                    style={[styles.modalBtn, styles.modalBtnDanger]}
                    activeOpacity={0.9}
                    onPress={confirmEmergency}
                  >
                    <Text style={styles.modalBtnDangerText}>Confirm</Text>
                  </TouchableOpacity>
                </View>
              </Pressable>
            </Pressable>
          </Modal>

          {/* ===================== */}
          {/* ✅ STOP CONFIRM MODAL */}
          {/* ===================== */}
          <Modal
            visible={stopOpen}
            transparent
            animationType="fade"
            onRequestClose={() => setStopOpen(false)}
          >
            <Pressable
              style={styles.modalBackdrop}
              onPress={() => setStopOpen(false)}
            >
              <Pressable style={[styles.modalCard, styles.modalOrangeBorder]} onPress={() => {}}>
                <View style={styles.modalHeaderRow}>
                  <View style={styles.modalHeaderLeft}>
                    <View style={styles.orangeDot} />
                    <Text style={styles.modalTitle}>Stop Confirmation</Text>
                  </View>
                </View>

                <Text style={styles.modalBodyText}>
                  This action cannot be undone. Do you want to stop?
                </Text>

                <View style={styles.modalBtnRow}>
                  <TouchableOpacity
                    style={[styles.modalBtn, styles.modalBtnCancel]}
                    activeOpacity={0.9}
                    onPress={() => setStopOpen(false)}
                  >
                    <Text style={styles.modalBtnCancelText}>Cancel</Text>
                  </TouchableOpacity>

                  <TouchableOpacity
                    style={[styles.modalBtn, styles.modalBtnConfirm]}
                    activeOpacity={0.9}
                    onPress={confirmStop}
                  >
                    <Text style={styles.modalBtnConfirmText}>Confirm</Text>
                  </TouchableOpacity>
                </View>
              </Pressable>
            </Pressable>
          </Modal>
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
    paddingBottom: 18,
  },

  topHeader: { alignItems: "center", marginBottom: 10 },
  headerTitle: {
    color: "rgba(255,255,255,0.85)",
    fontSize: 13,
    fontWeight: "600",
  },

  infoRow: { flexDirection: "row", alignItems: "center", marginBottom: 10 },
  infoCol: { flex: 1 },
  infoLeft: { alignItems: "flex-start" },
  infoCenter: { alignItems: "center" },
  infoRight: { alignItems: "flex-end" },

  infoText: { color: "rgba(255,255,255,0.70)", fontSize: 11 },
  infoStatus: { flexDirection: "row", alignItems: "center" },
  infoLoc: { flexDirection: "row", alignItems: "center" },

  dotGreen: {
    width: 8,
    height: 8,
    borderRadius: 999,
    backgroundColor: "#3DDC84",
    marginRight: 6,
  },

  divider: {
    height: 1,
    backgroundColor: "rgba(255,255,255,0.12)",
    marginBottom: 14,
  },

  recordWrap: { alignItems: "center", marginTop: 6, marginBottom: 14 },
  recordOuter: {
    width: 190,
    height: 190,
    borderRadius: 999,
    backgroundColor: "#C70000",
    alignItems: "center",
    justifyContent: "center",
  },
  recordInner: {
    width: 148,
    height: 148,
    borderRadius: 999,
    backgroundColor: "#B10000",
    alignItems: "center",
    justifyContent: "center",
  },
  stopSquare: {
    width: 34,
    height: 34,
    borderRadius: 8,
    backgroundColor: "rgba(255,255,255,0.85)",
    marginBottom: 10,
  },
  recTimer: {
    color: "rgba(255,255,255,0.80)",
    fontSize: 10,
    letterSpacing: 0.6,
  },
  recText: {
    marginTop: 6,
    color: "rgba(255,255,255,0.92)",
    fontSize: 13,
    fontWeight: "700",
    letterSpacing: 1,
  },

  waveRow: { flexDirection: "row", alignItems: "center", marginBottom: 14 },
  micIcon: {
    width: 34,
    height: 34,
    borderRadius: 12,
    backgroundColor: "rgba(0,0,0,0.18)",
    alignItems: "center",
    justifyContent: "center",
    marginRight: 10,
  },
  waveBars: {
    flex: 1,
    height: 34,
    backgroundColor: "rgba(0,0,0,0.14)",
    borderRadius: 12,
    paddingHorizontal: 10,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
  },
  bar: {
    width: 4,
    borderRadius: 999,
    backgroundColor: "rgba(255,255,255,0.75)",
  },

  transcriptCard: {
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "rgba(61,220,132,0.35)",
    padding: 12,
    marginBottom: 12,
  },
  transcriptHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginBottom: 10,
  },
  transLeft: { flexDirection: "row", alignItems: "center" },
  transTitle: {
    marginLeft: 8,
    color: "rgba(255,255,255,0.88)",
    fontSize: 12,
    fontWeight: "600",
  },
  listeningWrap: { flexDirection: "row", alignItems: "center" },
  dotGreenSmall: {
    width: 7,
    height: 7,
    borderRadius: 999,
    backgroundColor: "#3DDC84",
    marginRight: 6,
  },
  listeningText: { color: "rgba(255,255,255,0.65)", fontSize: 11 },
  transBody: {
    backgroundColor: "rgba(255,255,255,0.06)",
    borderRadius: 10,
    padding: 10,
    minHeight: 84,
  },
  transText: { color: "rgba(255,255,255,0.70)", fontSize: 11, lineHeight: 16 },

  snapshotBtn: {
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "rgba(255,176,32,0.35)",
    paddingVertical: 14,
    paddingHorizontal: 12,
    flexDirection: "row",
    alignItems: "center",
    marginBottom: 12,
  },
  snapshotIconBox: {
    width: 28,
    height: 28,
    borderRadius: 10,
    backgroundColor: "rgba(255,176,32,0.12)",
    alignItems: "center",
    justifyContent: "center",
    marginRight: 10,
  },
  snapshotText: {
    color: "rgba(255,255,255,0.85)",
    fontSize: 12,
    fontWeight: "600",
  },

  emergencyBtn: {
    backgroundColor: "#FF1E1E",
    borderRadius: 12,
    paddingVertical: 14,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 12,
  },
  emergencyText: {
    color: "white",
    fontSize: 12,
    fontWeight: "700",
    marginLeft: 8,
    letterSpacing: 0.3,
  },

  bottomRow: { flexDirection: "row", marginTop: 2 },
  markBtn: {
    flex: 1,
    backgroundColor: "#D28A2A",
    borderRadius: 12,
    paddingVertical: 14,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    marginRight: 10,
  },
  stopBtn: {
    flex: 1,
    backgroundColor: "rgba(0,0,0,0.22)",
    borderRadius: 12,
    paddingVertical: 14,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
  },
  bottomBtnText: {
    color: "white",
    fontSize: 12,
    fontWeight: "700",
    marginLeft: 8,
  },

  /* ========================= */
  /* ✅ MODAL STYLES (Figma-ish) */
  /* ========================= */
  modalBackdrop: {
    flex: 1,
    backgroundColor: "rgba(0,0,0,0.55)",
    alignItems: "center",
    justifyContent: "center",
    paddingHorizontal: 18,
  },
  modalCard: {
    width: "100%",
    maxWidth: 360,
    backgroundColor: "rgba(15,25,45,0.96)",
    borderRadius: 14,
    padding: 14,
    borderWidth: 1,
  },
  modalRedBorder: { borderColor: "rgba(255,80,80,0.45)" },
  modalOrangeBorder: { borderColor: "rgba(255,176,32,0.40)" },

  modalHeaderRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginBottom: 10,
  },
  modalHeaderLeft: { flexDirection: "row", alignItems: "center" },
  modalTitle: {
    marginLeft: 8,
    color: "rgba(255,255,255,0.90)",
    fontSize: 13,
    fontWeight: "700",
  },
  orangeDot: {
    width: 12,
    height: 12,
    borderRadius: 999,
    backgroundColor: "#FFB020",
  },

  modalBodyText: {
    color: "rgba(255,255,255,0.55)",
    fontSize: 11,
    lineHeight: 16,
    marginBottom: 14,
  },

  modalBtnRow: { flexDirection: "row", gap: 12 },
  modalBtn: {
    flex: 1,
    height: 40,
    borderRadius: 10,
    alignItems: "center",
    justifyContent: "center",
    borderWidth: 1,
  },
  modalBtnCancel: {
    backgroundColor: "rgba(255,255,255,0.06)",
    borderColor: "rgba(255,255,255,0.16)",
  },
  modalBtnCancelText: {
    color: "rgba(255,255,255,0.75)",
    fontSize: 12,
    fontWeight: "700",
  },

  // emergency confirm = red
  modalBtnDanger: {
    backgroundColor: "#FF1E1E",
    borderColor: "rgba(255,30,30,0.55)",
  },
  modalBtnDangerText: { color: "white", fontSize: 12, fontWeight: "800" },

  // stop confirm = orange
  modalBtnConfirm: {
    backgroundColor: "#F3B05A",
    borderColor: "rgba(243,176,90,0.55)",
  },
  modalBtnConfirmText: {
    color: "rgba(25,25,25,0.9)",
    fontSize: 12,
    fontWeight: "900",
  },
});
