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
import { useContext } from 'react';
import { AuthContext } from '../context/AuthContext';
import supabase from '../lib/supabase';

export default function RecordingScreen({ navigation, route }) {
  const [seconds, setSeconds] = useState(0);
  const [snapshotCount, setSnapshotCount] = useState(0);
  const [markCount, setMarkCount] = useState(0);
  
  const [emergencyConfirmOpen, setEmergencyConfirmOpen] = useState(false);
  const [stopOpen, setStopOpen] = useState(false);
  const [resolveConfirmOpen, setResolveConfirmOpen] = useState(false);
  const [alertModal, setAlertModal] = useState({ visible: false, title: "", message: "", type: "info" });

  const { profile, user } = useContext(AuthContext);
  const [backupData, setBackupData] = useState(null);
  const [emergencyTriggered, setEmergencyTriggered] = useState(false);
  const [currentRequestId, setCurrentRequestId] = useState(null);

  useEffect(() => {
    const t = setInterval(() => setSeconds((s) => s + 1), 1000);
    return () => clearInterval(t);
  }, []);

  
  const backupDataMemo = useMemo(() => {
    const incoming = route?.params?.backupData;
    if (incoming) return incoming;

    return {
      enforcer: profile?.display_name || "Juan Bartolome",
      location: "Llano Rd., Caloocan City",
      time: "8:21 pm",
      responders: 4,
      coords: { latitude: 14.7566, longitude: 121.0447 },
    };
  }, [route?.params?.backupData, profile?.display_name]);

  const timeText = useMemo(() => {
    const mm = String(Math.floor(seconds / 60)).padStart(2, "0");
    const ss = String(seconds % 60).padStart(2, "0");
    return `${mm}:${ss}`;
  }, [seconds]);

  const handleSnapshot = () => {
    setSnapshotCount((prev) => prev + 1);
    console.log(`Snapshot taken! Total snapshots: ${snapshotCount + 1}`);
  };
  
  const handleMark = () => {
    setMarkCount((prev) => prev + 1);
    console.log(`Mark added! Total marks: ${markCount + 1}`);
  };

 
  const handleEmergency = () => setEmergencyConfirmOpen(true);

  
  const handleStop = () => setStopOpen(true);

  
  const confirmEmergency = async () => {
    setEmergencyConfirmOpen(false);
    console.log('[RecordingScreen] Emergency backup initiated');
    console.log('[RecordingScreen] User ID:', user?.id);
    console.log('[RecordingScreen] User profile:', profile);

    const badge = profile?.badge || '4521';
    // Generate unique request_id using year + badge last 4 + timestamp last 4
    const year = new Date().getFullYear().toString().slice(-2); // Last 2 digits of year (e.g., 26 from 2026)
    const badgeLast4 = badge.slice(-4); // Last 4 digits of badge (e.g., 6500)
    const timestamp = Date.now().toString().slice(-4); // Last 4 digits of timestamp (e.g., 4253)
    const request_id = `REQ${year}${badgeLast4}${timestamp}`;
    const enforcer = profile?.display_name || 'Juan Bartolome';
    const location = 'Camarin Rd.';
    const time = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    const responders = 0;
    const coords = { latitude: 14.7566, longitude: 121.0447 };

    console.log('[RecordingScreen] Emergency backup data:', {
      request_id,
      enforcer,
      location,
      time,
      responders,
    });

    try {
      // Step 1: Insert into emergency_backups table
      console.log('[RecordingScreen] Inserting emergency backup into database...');
      const { data: insertData, error: insertError } = await supabase
        .from('emergency_backups')
        .insert({
          request_id,
          enforcer,
          location,
          time,
          responders,
        });

      if (insertError) {
        console.error('[RecordingScreen] Insert error:', insertError);
        console.error('[RecordingScreen] Error details:', {
          message: insertError.message,
          code: insertError.code,
          hint: insertError.hint,
        });
        throw insertError;
      }

      console.log('[RecordingScreen] Emergency backup inserted successfully:', insertData);

      // Step 2: Get session for push notification
      console.log('[RecordingScreen] Getting session for push notification...');
      const sessionData = await supabase.auth.getSession();
      const session = sessionData?.data?.session;

      if (!session) {
        console.error('[RecordingScreen] No session available for push notification');
        throw new Error('No active session');
      }

      console.log('[RecordingScreen] Session retrieved, access token present:', !!session.access_token);

      // Step 3: Send push notifications
      console.log('[RecordingScreen] Sending push notification...');
      
      // Validate user ID
      if (!user?.id) {
        throw new Error('User ID is not available. Cannot send emergency notifications.');
      }
      
      const notificationPayload = {
        request_id,
        enforcer,
        location,
        time,
        triggered_by_user_id: user.id,
      };
      
      console.log('[RecordingScreen] ========================================');
      console.log('[RecordingScreen] NOTIFICATION PAYLOAD:');
      console.log('[RecordingScreen] Request ID:', request_id);
      console.log('[RecordingScreen] Enforcer:', enforcer);
      console.log('[RecordingScreen] Location:', location);
      console.log('[RecordingScreen] Time:', time);
      console.log('[RecordingScreen] Triggered by User ID:', user.id);
      console.log('[RecordingScreen] ========================================');

      const supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inpla2JvbmJ4d2NjZ3NmYWdycnBoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjgzOTQyOTUsImV4cCI6MjA4Mzk3MDI5NX0.0ss5U-uXryhWGf89ucndqNK8-Bzj_GRZ-4-Xap6ytHg";

      console.log('[RecordingScreen] Calling edge function endpoint...');
      const notificationResponse = await fetch(
        'https://zekbonbxwccgsfagrrph.supabase.co/functions/v1/send-emergency-notification',
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${supabaseAnonKey}`,
          },
          body: JSON.stringify(notificationPayload),
        }
      );

      console.log('[RecordingScreen] Fetch call completed');
      console.log('[RecordingScreen] Response status:', notificationResponse.status);

      console.log('[RecordingScreen] Notification response status:', notificationResponse.status);

      if (!notificationResponse.ok) {
        const errorText = await notificationResponse.text();
        console.error('[RecordingScreen] Notification error response:', errorText);
        console.warn('[RecordingScreen] Push notification failed, but emergency backup was recorded');
      } else {
        const notificationData = await notificationResponse.json();
        console.log('[RecordingScreen] ✅ Push notification sent successfully!');
        console.log('[RecordingScreen] Notifications sent to:', notificationData.sent, 'users');
        console.log('[RecordingScreen] Total users notified:', notificationData.total);
        console.log('[RecordingScreen] Response:', notificationData);
      }

      console.log('[RecordingScreen] Emergency backup completed successfully');
      setAlertModal({
        visible: true,
        title: "Success",
        message: "Emergency backup request sent to nearby units.",
        type: "success"
      });
      setEmergencyTriggered(true);
      setCurrentRequestId(request_id);
    } catch (err) {
      console.error('[RecordingScreen] Failed to send emergency backup:', err);
      console.error('[RecordingScreen] Error stack:', err.stack);
      console.error('[RecordingScreen] Error details:', {
        message: err?.message,
        code: err?.code,
        response: err?.response,
      });
      setAlertModal({
        visible: true,
        title: "Error",
        message: `Failed to send request: ${err?.message || 'Unknown error'}`,
        type: "error"
      });
    }
  };

  const resolveEmergency = async () => {
    if (!currentRequestId) return;
    try {
      const { error } = await supabase
        .from('emergency_backups')
        .update({ status: 'RESOLVED' })
        .eq('request_id', currentRequestId);
      if (error) throw error;
      setEmergencyTriggered(false);
      setCurrentRequestId(null);
      setAlertModal({ visible: true, title: "Resolved", message: "Emergency resolved.", type: "success" });
    } catch (err) {
      console.error('Failed to resolve emergency:', err);
      setAlertModal({ visible: true, title: "Error", message: "Failed to resolve. Try again.", type: "error" });
    }
  };

  
  const declineBackupRequest = () => {
    setBackupNotifyOpen(false);
  };

  
  const confirmStop = () => {
    console.log("Stop Recording CONFIRMED (simulation)");
    setStopOpen(false);
    navigation.navigate("IncidentSummary", { duration: seconds });
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
          <View style={styles.topHeader}>
            <Text style={styles.headerTitle}>Enforcer Dashboard</Text>
          </View>

          <View style={styles.infoRow}>
            <View style={[styles.infoCol, styles.infoLeft]}>
              <Text style={styles.infoText}>ID: {profile?.badge || '4521'}</Text>
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

          <View style={styles.divider} />

          <View style={styles.recordWrap}>
            <View style={styles.recordOuter}>
              <View style={styles.recordInner}>
                <View style={styles.stopSquare} />
                <Text style={styles.recTimer}>REC {timeText}</Text>
                <Text style={styles.recText}>RECORDING</Text>
              </View>
            </View>
          </View>

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

          <TouchableOpacity
            style={styles.snapshotBtn}
            activeOpacity={0.85}
            onPress={handleSnapshot}
          >
            <View style={styles.snapshotIconBox}>
              <Ionicons name="camera" size={18} color="#FFB020" />
            </View>
            <Text style={styles.snapshotText}>Snapshot</Text>
            <Text style={styles.counterText}>{snapshotCount}</Text>
          </TouchableOpacity>

          <TouchableOpacity
            style={[styles.emergencyBtn, emergencyTriggered && styles.emergencyBtnResolved]}
            activeOpacity={0.9}
            onPress={emergencyTriggered ? () => setResolveConfirmOpen(true) : handleEmergency}
          >
            <Ionicons name={emergencyTriggered ? "checkmark-circle-outline" : "warning-outline"} size={16} color="white" />
            <Text style={styles.emergencyText}>{emergencyTriggered ? "Resolved" : "Emergency Backup"}</Text>
          </TouchableOpacity>

          <View style={styles.bottomRow}>
            <TouchableOpacity
              style={styles.markBtn}
              activeOpacity={0.9}
              onPress={handleMark}
            >
              <Ionicons name="flag-outline" size={16} color="white" />
              <Text style={styles.bottomBtnText}>Mark</Text>
              <Text style={styles.counterText}>{markCount}</Text>
            </TouchableOpacity>

            <TouchableOpacity
              style={styles.stopBtn}
              activeOpacity={0.9}
              onPress={emergencyTriggered ? () => alert('Resolve the emergency first before stopping the recording.') : handleStop}
            >
              <Ionicons
                name="stop-circle-outline"
                size={18}
                color="rgba(255,255,255,0.9)"
              />
              <Text style={styles.bottomBtnText}>Stop</Text>
            </TouchableOpacity>
          </View>

        
          <Modal
            visible={emergencyConfirmOpen}
            transparent
            animationType="fade"
            onRequestClose={() => setEmergencyConfirmOpen(false)}
          >
            <Pressable
              style={styles.modalBackdrop}
              onPress={() => setEmergencyConfirmOpen(false)}
            >
              <Pressable
                style={[styles.modalCard, styles.modalRedBorder]}
                onPress={() => {}}
              >
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
                    onPress={() => setEmergencyConfirmOpen(false)}
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
              <Pressable
                style={[styles.modalCard, styles.modalOrangeBorder]}
                onPress={() => {}}
              >
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

          <Modal
            visible={resolveConfirmOpen}
            transparent
            animationType="fade"
            onRequestClose={() => setResolveConfirmOpen(false)}
          >
            <Pressable
              style={styles.modalBackdrop}
              onPress={() => setResolveConfirmOpen(false)}
            >
              <Pressable
                style={[styles.modalCard, styles.modalGreenBorder]}
                onPress={() => {}}
              >
                <View style={styles.modalHeaderRow}>
                  <View style={styles.modalHeaderLeft}>
                    <Ionicons name="checkmark-circle-outline" size={18} color="#3DDC84" />
                    <Text style={styles.modalTitle}>Resolve Emergency</Text>
                  </View>
                </View>

                <Text style={styles.modalBodyText}>
                  Are you sure you want to mark this emergency as resolved? This action cannot be undone.
                </Text>

                <View style={styles.modalBtnRow}>
                  <TouchableOpacity
                    style={[styles.modalBtn, styles.modalBtnCancel]}
                    activeOpacity={0.9}
                    onPress={() => setResolveConfirmOpen(false)}
                  >
                    <Text style={styles.modalBtnCancelText}>Cancel</Text>
                  </TouchableOpacity>

                  <TouchableOpacity
                    style={[styles.modalBtn, styles.modalBtnConfirm]}
                    activeOpacity={0.9}
                    onPress={() => {
                      setResolveConfirmOpen(false);
                      resolveEmergency();
                    }}
                  >
                    <Text style={styles.modalBtnConfirmText}>Confirm</Text>
                  </TouchableOpacity>
                </View>
              </Pressable>
            </Pressable>
          </Modal>

          <Modal
            visible={alertModal.visible}
            transparent
            animationType="fade"
            onRequestClose={() => setAlertModal({ ...alertModal, visible: false })}
          >
            <Pressable
              style={styles.modalBackdrop}
              onPress={() => setAlertModal({ ...alertModal, visible: false })}
            >
              <Pressable
                style={[styles.modalCard, alertModal.type === "error" ? styles.modalRedBorder : styles.modalGreenBorder]}
                onPress={() => {}}
              >
                <View style={styles.modalHeaderRow}>
                  <View style={styles.modalHeaderLeft}>
                    <Ionicons
                      name={alertModal.type === "error" ? "warning-outline" : "checkmark-circle-outline"}
                      size={18}
                      color={alertModal.type === "error" ? "#FF4A4A" : "#3DDC84"}
                    />
                    <Text style={styles.modalTitle}>{alertModal.title}</Text>
                  </View>
                </View>

                <Text style={styles.modalBodyText}>{alertModal.message}</Text>

                <View style={styles.modalBtnRow}>
                  <TouchableOpacity
                    style={[styles.modalBtn, styles.modalBtnCancel]}
                    activeOpacity={0.9}
                    onPress={() => setAlertModal({ ...alertModal, visible: false })}
                  >
                    <Text style={styles.modalBtnCancelText}>OK</Text>
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

  recordWrap: { alignItems: "center", marginTop: 18, marginBottom: 20 },
  recordOuter: {
    width: 200,
    height: 200,
    borderRadius: 999,
    backgroundColor: "#C70000",
    alignItems: "center",
    justifyContent: "center",
  },
  recordInner: {
    width: 150,
    height: 150,
    borderRadius: 999,
    backgroundColor: "#B10000",
    alignItems: "center",
    justifyContent: "center",
  },
  stopSquare: {
    width: 40,
    height: 40,
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
    width: 40,
    height: 40,
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
    width: 3,
    borderRadius: 999,
    backgroundColor: "rgba(255,255,255,0.75)",
  },

  transcriptCard: {
    height: 200,
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
    minHeight: 140,
  },
  transText: { color: "rgba(255,255,255,0.70)", fontSize: 12, lineHeight: 16 },

  snapshotBtn: {
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "rgba(255,176,32,0.35)",
    paddingVertical: 14,
    paddingHorizontal: 20,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
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
    flex: 1,
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
  emergencyBtnResolved: {
    backgroundColor: "#3DDC84",
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
    justifyContent: "space-between",
    paddingHorizontal: 20,
    marginRight: 10,
  },
  stopBtn: {
    flex: 1,
    backgroundColor: "rgba(0,0,0,0.22)",
    borderRadius: 12,
    paddingVertical: 14,
    paddingHorizontal: 20,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
  },
  bottomBtnText: {
    color: "white",
    fontSize: 12,
    fontWeight: "700",
    marginLeft: 8,
    flex: 1,
  },

  counterText: {
    color: "rgba(255,255,255,0.85)",
    fontSize: 13,
    fontWeight: "700",
  },
  
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
  modalGreenBorder: { borderColor: "rgba(61,220,132,0.55)" },

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
    marginBottom: 12,
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

  modalBtnDanger: {
    backgroundColor: "#FF1E1E",
    borderColor: "rgba(255,30,30,0.55)",
  },
  modalBtnDangerText: { color: "white", fontSize: 12, fontWeight: "800" },

  modalBtnConfirm: {
    backgroundColor: "#F3B05A",
    borderColor: "rgba(243,176,90,0.55)",
  },
  modalBtnConfirmText: {
    color: "rgba(25,25,25,0.9)",
    fontSize: 12,
    fontWeight: "900",
  },

  
  popupBackdrop: {
    flex: 1,
    backgroundColor: "rgba(0,0,0,0.55)",
    justifyContent: "flex-start",
    paddingTop: 24,
    paddingHorizontal: 18,
  },
  popupCard: {
    width: "100%",
    backgroundColor: "rgba(15,25,45,0.96)",
    borderRadius: 14,
    padding: 14,
    borderWidth: 2,
    borderColor: "rgba(234, 63, 63, 0.5)",
  },
  popupHeader: { flexDirection: "row", alignItems: "center", gap: 10 },
  popupTitle: {
    color: "rgba(255,255,255,0.92)",
    fontSize: 13,
    fontWeight: "800",
  },
  popupLine: {
    color: "rgba(255,255,255,0.65)",
    fontSize: 11,
    marginTop: 6,
  },
  popupValue: { color: "rgba(255,255,255,0.90)", fontWeight: "800" },
  popupBtnRow: { flexDirection: "row", gap: 12, marginTop: 12 },
  popupBtn: {
    flex: 1,
    height: 40,
    borderRadius: 10,
    alignItems: "center",
    justifyContent: "center",
  },
  popupAccept: { backgroundColor: "#3DDC84" },
  popupDecline: { backgroundColor: "#FF1E1E" },
  popupAcceptText: {
    color: "rgba(15,25,45,0.95)",
    fontSize: 12,
    fontWeight: "900",
  },
  popupDeclineText: { color: "white", fontSize: 12, fontWeight: "900" },
});