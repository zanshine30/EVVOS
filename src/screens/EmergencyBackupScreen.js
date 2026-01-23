import React, { useMemo, useState, useEffect } from "react";
import { View, Text, StyleSheet, TouchableOpacity, Alert, ActivityIndicator, Modal } from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Ionicons } from "@expo/vector-icons";
import MapView, { Marker } from "react-native-maps";
import { SafeAreaView } from "react-native-safe-area-context";
import supabase from '../lib/supabase';

export default function EmergencyBackupScreen({ navigation, route }) {
  const [backupData, setBackupData] = useState(route?.params?.backupData);
  const [status, setStatus] = useState("En Route"); // "On Scene"
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const [mounted, setMounted] = useState(true);
  const [resolveBlockedModalOpen, setResolveBlockedModalOpen] = useState(false);
  const [cancelConfirmModalOpen, setCancelConfirmModalOpen] = useState(false);
  const [cancelLoading, setCancelLoading] = useState(false);

  useEffect(() => {
    setMounted(true);
    return () => setMounted(false);
  }, []);

  useEffect(() => {
    if (!mounted) return;

    const requestId = route?.params?.request_id;
    console.log('[EmergencyBackupScreen] ========================================');
    console.log('[EmergencyBackupScreen] Screen mounted with request_id:', requestId);
    console.log('[EmergencyBackupScreen] Route params:', route?.params);
    console.log('[EmergencyBackupScreen] Initial backupData:', backupData);
    console.log('[EmergencyBackupScreen] ========================================');
    
    if (requestId) {
      setLoading(true);
      setError(null);
      const fetchData = async () => {
        try {
          console.log('[EmergencyBackupScreen] 1️⃣  Fetching backup details for request_id:', requestId);
          const { data, error: fetchError } = await supabase
            .from('emergency_backups')
            .select('*')
            .eq('request_id', requestId)
            .single();
          
          if (!mounted) {
            console.log('[EmergencyBackupScreen] Component unmounted, skipping state updates');
            return;
          }
          
          if (fetchError) {
            console.error('[EmergencyBackupScreen] ❌ Error fetching data:', fetchError);
            setError(fetchError.message);
            Alert.alert('Error', 'Failed to load emergency backup details: ' + fetchError.message);
            setLoading(false);
            return;
          }
          
          if (data) {
            console.log('[EmergencyBackupScreen] ✅ 2️⃣  Data fetched successfully:', {
              enforcer: data.enforcer,
              location: data.location,
              responders: data.responders,
              status: data.status,
            });
            
            setBackupData({
              enforcer: data.enforcer,
              location: data.location,
              time: data.time,
              responders: data.responders,
              coords: { latitude: 14.7566, longitude: 121.0447 },
              request_id: data.request_id,
              status: data.status,
            });
            setError(null);
          } else {
            console.warn('[EmergencyBackupScreen] ⚠️  No data found for request_id:', requestId);
            setError('No emergency backup found');
            Alert.alert('Error', 'Emergency backup not found');
          }
        } catch (err) {
          console.error('[EmergencyBackupScreen] ❌ Fetch exception:', err);
          if (mounted) {
            setError(err.message);
            Alert.alert('Error', 'Failed to load data: ' + err.message);
          }
        } finally {
          if (mounted) {
            setLoading(false);
          }
        }
      };
      
      fetchData();
    } else {
      console.warn('[EmergencyBackupScreen] ⚠️  No request_id provided in route params');
      setError('No request ID provided');
      setLoading(false);
    }
  }, [route?.params?.request_id, mounted]);

  // Poll for status updates every second
  useEffect(() => {
    if (!requestId || !mounted) return;

    console.log('[EmergencyBackupScreen] Starting status polling for request_id:', requestId);
    
    const pollInterval = setInterval(async () => {
      try {
        const { data, error } = await supabase
          .from('emergency_backups')
          .select('status')
          .eq('request_id', requestId)
          .single();

        if (!mounted) {
          console.log('[EmergencyBackupScreen] Component unmounted, stopping poll');
          return;
        }

        if (error) {
          console.warn('[EmergencyBackupScreen] Poll error:', error);
          return;
        }

        if (data && data.status !== backupData?.status) {
          console.log('[EmergencyBackupScreen] ✅ Status updated:', backupData?.status, '→', data.status);
          setBackupData(prev => ({
            ...prev,
            status: data.status,
          }));
        }
      } catch (err) {
        console.warn('[EmergencyBackupScreen] Poll exception:', err);
      }
    }, 1000); // Poll every 1 second

    return () => {
      console.log('[EmergencyBackupScreen] Stopping status polling');
      clearInterval(pollInterval);
    };
  }, [requestId, mounted, backupData?.status]);

  // Poll for responder count updates every second when cancel modal is open
  useEffect(() => {
    if (!requestId || !mounted || !cancelConfirmModalOpen) return;

    console.log('[EmergencyBackupScreen] Starting responder count polling for request_id:', requestId);
    
    const pollInterval = setInterval(async () => {
      try {
        const { data, error } = await supabase
          .from('emergency_backups')
          .select('responders')
          .eq('request_id', requestId)
          .single();

        if (!mounted) {
          console.log('[EmergencyBackupScreen] Component unmounted, stopping responder poll');
          return;
        }

        if (error) {
          console.warn('[EmergencyBackupScreen] Responder poll error:', error);
          return;
        }

        if (data && data.responders !== backupData?.responders) {
          console.log('[EmergencyBackupScreen] ✅ Responder count updated:', backupData?.responders, '→', data.responders);
          setBackupData(prev => ({
            ...prev,
            responders: data.responders,
          }));
        }
      } catch (err) {
        console.warn('[EmergencyBackupScreen] Responder poll exception:', err);
      }
    }, 1000); // Poll every 1 second

    return () => {
      console.log('[EmergencyBackupScreen] Stopping responder count polling');
      clearInterval(pollInterval);
    };
  }, [requestId, mounted, cancelConfirmModalOpen, backupData?.responders]);

  const coords = backupData?.coords || { latitude: 14.7566, longitude: 121.0447 };
  const name = backupData?.enforcer ?? "Juan Bartolome";
  const location = backupData?.location ?? "Llano Rd., Caloocan City";
  const time = backupData?.time ?? "8:21 pm";
  const responders = backupData?.responders ?? 4;
  const requestId = backupData?.request_id;

  // Refresh function to get latest data
  const handleRefresh = async () => {
    if (requestId) {
      setLoading(true);
      try {
        console.log('[EmergencyBackupScreen] Refreshing data...');
        const { data, error } = await supabase
          .from('emergency_backups')
          .select('*')
          .eq('request_id', requestId)
          .single();
        
        if (error) {
          console.error('[EmergencyBackupScreen] Refresh error:', error);
          return;
        }
        
        if (data) {
          console.log('[EmergencyBackupScreen] ✅ Data refreshed:', { responders: data.responders });
          setBackupData({
            enforcer: data.enforcer,
            location: data.location,
            time: data.time,
            responders: data.responders,
            coords: { latitude: 14.7566, longitude: 121.0447 },
            request_id: data.request_id,
            status: data.status,
          });
        }
      } catch (err) {
        console.error('[EmergencyBackupScreen] Refresh failed:', err);
      } finally {
        setLoading(false);
      }
    }
  };

  // Handle cancel button - shows confirmation modal
  const handleCancelPress = () => {
    console.log('[EmergencyBackupScreen] Cancel button pressed, opening confirmation modal');
    setCancelConfirmModalOpen(true);
  };

  // Confirm cancel and decrement responders
  const handleCancelConfirm = async () => {
    if (!requestId) {
      Alert.alert('Error', 'Request ID is missing');
      return;
    }

    try {
      setCancelLoading(true);
      console.log('[EmergencyBackupScreen] Decrementing responders for request_id:', requestId);

      // Fetch current responder count
      const { data: current, error: fetchError } = await supabase
        .from('emergency_backups')
        .select('responders')
        .eq('request_id', requestId)
        .single();

      if (fetchError) {
        console.error('[EmergencyBackupScreen] Fetch error:', fetchError);
        Alert.alert('Error', 'Failed to update responder count');
        setCancelLoading(false);
        return;
      }

      // Decrement responder count (but not below 0)
      const currentCount = current?.responders || 0;
      const newResponderCount = Math.max(0, currentCount - 1);
      console.log('[EmergencyBackupScreen] Responders:', currentCount, '→', newResponderCount);

      // Update in database
      const { error: updateError } = await supabase
        .from('emergency_backups')
        .update({ responders: newResponderCount })
        .eq('request_id', requestId);

      if (updateError) {
        console.error('[EmergencyBackupScreen] Update error:', updateError);
        Alert.alert('Error', 'Failed to update responder count');
        setCancelLoading(false);
        return;
      }

      console.log('[EmergencyBackupScreen] ✅ Responders updated successfully');
      setCancelConfirmModalOpen(false);
      setCancelLoading(false);

      // Navigate back to Home
      navigation.reset({
        index: 0,
        routes: [{ name: "Home" }],
      });
    } catch (err) {
      console.error('[EmergencyBackupScreen] Cancel confirm error:', err);
      Alert.alert('Error', 'Failed to process cancellation');
      setCancelLoading(false);
    }
  };

  return (
    <LinearGradient
      colors={["#0B1A33", "#3D5F91"]}
      start={{ x: 0.5, y: 0 }}
      end={{ x: 0.5, y: 1 }}
      style={styles.gradient}
    >
      <SafeAreaView style={styles.safe}>
        {loading && !backupData && (
          <View style={{ flex: 1, justifyContent: 'center', alignItems: 'center' }}>
            <ActivityIndicator size="large" color="#2E78E6" />
            <Text style={{ marginTop: 16, color: '#fff', fontSize: 14 }}>Loading emergency details...</Text>
          </View>
        )}
        
        {error && !backupData && (
          <View style={{ flex: 1, justifyContent: 'center', alignItems: 'center', paddingHorizontal: 20 }}>
            <Ionicons name="alert-circle" size={48} color="#FF1E1E" />
            <Text style={{ marginTop: 16, color: '#fff', fontSize: 14, textAlign: 'center' }}>
              {error}
            </Text>
            <TouchableOpacity
              style={{ marginTop: 20, backgroundColor: '#2E78E6', paddingHorizontal: 20, paddingVertical: 10, borderRadius: 8 }}
              onPress={() => navigation.goBack()}
            >
              <Text style={{ color: 'white', fontWeight: 'bold' }}>Go Back</Text>
            </TouchableOpacity>
          </View>
        )}
        
        {backupData && (
        <View style={styles.container}>
          <View style={styles.topHeader}>
            <View style={styles.headerRow}>
              <Text style={styles.headerTitle}>Emergency Backup</Text>
              <TouchableOpacity onPress={handleRefresh} activeOpacity={0.7}>
                <Ionicons name="refresh" size={18} color="rgba(255,255,255,0.85)" />
              </TouchableOpacity>
            </View>
            <Text style={styles.sentByText}>Sent by {name}</Text>
          </View>

          
          <View style={[styles.card, styles.cardGreen]}>
            <View style={styles.cardHeaderRow}>
              <View style={[styles.pill, styles.pillGreen]}>
                <Text style={styles.pillText}>REQUEST</Text>
              </View>
              <Ionicons name="shield-checkmark-outline" size={18} color="#17F39A" />
            </View>

            <Text style={styles.line}>
              Name: <Text style={styles.value}>{name}</Text>
            </Text>
            <Text style={styles.line}>
              Location: <Text style={styles.value}>{location}</Text>
            </Text>
            <Text style={styles.line}>
              Time: <Text style={styles.value}>{time}</Text>
            </Text>
            <Text style={styles.line}>
              No. of Responders/: <Text style={styles.value}>{responders}</Text>
            </Text>
          </View>

          
          <View style={[styles.card, styles.cardBlue]}>
            <View style={styles.cardHeaderRow}>
              <View style={[styles.pill, styles.pillBlue]}>
                <Text style={styles.pillText}>LOCATION</Text>
              </View>
              <Ionicons name="location-outline" size={18} color="#FF4A4A" />
            </View>

            <View style={styles.mapWrap}>
              {/* Temporary black placeholder - MapView disabled until Google Maps API is configured */}
              <View style={{ flex: 1, backgroundColor: '#000' }} />
            </View>

            <TouchableOpacity style={styles.viewLocationBtn} activeOpacity={0.9}>
              <Text style={styles.viewLocationText}>View Location</Text>
            </TouchableOpacity>
          </View>

         
          <View style={[styles.card, styles.cardGreen]}>
            <View style={styles.cardHeaderRow}>
              <View style={[styles.pill, styles.pillGreen]}>
                <Text style={styles.pillText}>STATUS</Text>
              </View>
              <Ionicons name="pulse-outline" size={18} color="rgba(255,255,255,0.85)" />
            </View>

            <View style={styles.statusRow}>
              <TouchableOpacity
                style={[styles.statusBtn, status === "En Route" && styles.statusBtnActive]}
                onPress={() => setStatus("En Route")}
                activeOpacity={0.9}
              >
                <Text style={[styles.statusText, status === "En Route" && styles.statusTextActive]}>
                  En Route
                </Text>
              </TouchableOpacity>

              <TouchableOpacity
                style={[styles.statusBtn, status === "On Scene" && styles.statusBtnActive]}
                onPress={() => setStatus("On Scene")}
                activeOpacity={0.9}
              >
                <Text style={[styles.statusText, status === "On Scene" && styles.statusTextActive]}>
                  On Scene
                </Text>
              </TouchableOpacity>
            </View>
          </View>

          
          <View style={styles.bottomRow}>
            <TouchableOpacity
              style={[
                styles.bottomBtn,
                styles.resolved,
                backupData?.status !== 'RESOLVED' && styles.resolvedDisabled
              ]}
              activeOpacity={backupData?.status === 'RESOLVED' ? 0.9 : 1}
              onPress={async () => {
                if (backupData?.status !== 'RESOLVED') {
                  setResolveBlockedModalOpen(true);
                  return;
                }
                if (requestId) {
                  try {
                    await supabase.from('emergency_backups').update({ status: 'RESOLVED' }).eq('request_id', requestId);
                  } catch (err) {
                    console.error('Failed to update status:', err);
                  }
                }
                navigation.reset({
                  index: 0,
                  routes: [{ name: "Home" }], // ✅ goes back to Home screen
                });
              }}
            >
              <Text style={[styles.bottomTextDark, backupData?.status !== 'RESOLVED' && styles.resolvedDisabledText]}>
                {backupData?.status === 'RESOLVED' ? 'RESOLVED' : 'AWAITING REQUESTER'}
              </Text>
            </TouchableOpacity>

            <TouchableOpacity
              style={[styles.bottomBtn, styles.cancel]}
              activeOpacity={0.9}
              onPress={handleCancelPress}
            >
              <Text style={styles.bottomText}>CANCEL</Text>
            </TouchableOpacity>
          </View>
        </View>
        )}
      </SafeAreaView>

      <Modal visible={resolveBlockedModalOpen} transparent animationType="fade">
        <View style={styles.modalBackdrop}>
          <View style={[styles.modalCard, styles.modalRedBorder]}>
            <View style={styles.modalHeaderRow}>
              <View style={styles.modalHeaderLeft}>
                <Ionicons name="alert-circle" size={20} color="#FF5050" />
                <Text style={styles.modalTitle}>Cannot Resolve</Text>
              </View>
              <TouchableOpacity onPress={() => setResolveBlockedModalOpen(false)} activeOpacity={0.7}>
                <Ionicons name="close" size={20} color="rgba(255,255,255,0.65)" />
              </TouchableOpacity>
            </View>

            <Text style={styles.modalBodyText}>
              The requester must mark this emergency as resolved first before you can declare it resolved.
            </Text>

            <View style={styles.modalBtnRow}>
              <TouchableOpacity
                style={[styles.modalBtn, styles.modalBtnCancel]}
                onPress={() => setResolveBlockedModalOpen(false)}
                activeOpacity={0.9}
              >
                <Text style={styles.modalBtnCancelText}>OK</Text>
              </TouchableOpacity>
            </View>
          </View>
        </View>
      </Modal>

      <Modal visible={cancelConfirmModalOpen} transparent animationType="fade">
        <View style={styles.modalBackdrop}>
          <View style={[styles.modalCard, styles.modalRedBorder]}>
            <View style={styles.modalHeaderRow}>
              <View style={styles.modalHeaderLeft}>
                <Ionicons name="help-circle" size={20} color="#FF5050" />
                <Text style={styles.modalTitle}>Cancel Response?</Text>
              </View>
              <TouchableOpacity onPress={() => !cancelLoading && setCancelConfirmModalOpen(false)} activeOpacity={0.7} disabled={cancelLoading}>
                <Ionicons name="close" size={20} color="rgba(255,255,255,0.65)" />
              </TouchableOpacity>
            </View>

            <Text style={styles.modalBodyText}>
              Are you sure you want to cancel your response? This will remove you from the responder list.
            </Text>

            <View style={styles.modalBtnRow}>
              <TouchableOpacity
                style={[styles.modalBtn, styles.modalBtnCancel]}
                onPress={() => setCancelConfirmModalOpen(false)}
                activeOpacity={0.9}
                disabled={cancelLoading}
              >
                <Text style={styles.modalBtnCancelText}>KEEP RESPONDING</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={[styles.modalBtn, styles.modalBtnConfirm, cancelLoading && styles.modalBtnConfirmLoading]}
                onPress={handleCancelConfirm}
                activeOpacity={0.9}
                disabled={cancelLoading}
              >
                {cancelLoading ? (
                  <ActivityIndicator size="small" color="#FF5050" />
                ) : (
                  <Text style={styles.modalBtnConfirmText}>CANCEL RESPONSE</Text>
                )}
              </TouchableOpacity>
            </View>
          </View>
        </View>
      </Modal>
    </LinearGradient>
  );
}

const styles = StyleSheet.create({
  gradient: { flex: 1 },
  safe: { flex: 1 },

  container: {
    flex: 1,
    paddingHorizontal: 18,
    paddingTop: 6,
    paddingBottom: 18,
    gap: 12,
  },

  topHeader: { alignItems: "center", marginBottom: 6 },
  headerRow: { flexDirection: "row", alignItems: "center", justifyContent: "center", width: "100%" },
  headerTitle: { color: "rgba(255,255,255,0.90)", fontSize: 13, fontWeight: "700", flex: 1, textAlign: "center" },
  sentByText: { color: "rgba(255,255,255,0.65)", fontSize: 11, marginTop: 4, fontStyle: "italic" },

  card: {
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 12,
    borderWidth: 1,
    padding: 12,
  },
  cardGreen: { borderColor: "rgba(61,220,132,0.35)" },
  cardBlue: { borderColor: "rgba(120,170,255,0.30)" },

  cardHeaderRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginBottom: 10,
  },

  pill: { paddingHorizontal: 10, paddingVertical: 6, borderRadius: 999, borderWidth: 1 },
  pillGreen: { backgroundColor: "rgba(23,243,154,0.10)", borderColor: "rgba(23,243,154,0.35)" },
  pillBlue: { backgroundColor: "rgba(120,170,255,0.10)", borderColor: "rgba(120,170,255,0.35)" },
  pillText: { color: "rgba(255,255,255,0.90)", fontSize: 11, fontWeight: "800", letterSpacing: 0.3 },

  line: { color: "rgba(255,255,255,0.65)", fontSize: 12, marginTop: 6 },
  value: { color: "rgba(255,255,255,0.90)", fontWeight: "800" },

  mapWrap: {
    height: 190,
    borderRadius: 12,
    overflow: "hidden",
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.10)",
  },
  map: { flex: 1 },

  viewLocationBtn: {
    marginTop: 10,
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.12)",
    paddingVertical: 12,
    alignItems: "center",
  },
  viewLocationText: { color: "rgba(255,255,255,0.85)", fontSize: 12, fontWeight: "800" },

  statusRow: { flexDirection: "row", gap: 10, marginTop: 4 },
  statusBtn: {
    flex: 1,
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.12)",
    paddingVertical: 12,
    alignItems: "center",
  },
  statusBtnActive: {
    backgroundColor: "rgba(23,243,154,0.10)",
    borderColor: "rgba(23,243,154,0.35)",
  },
  statusText: { color: "rgba(255,255,255,0.65)", fontSize: 12, fontWeight: "800" },
  statusTextActive: { color: "rgba(255,255,255,0.92)" },

  bottomRow: { marginTop: "auto", flexDirection: "row", gap: 10 },
  bottomBtn: { flex: 1, borderRadius: 12, paddingVertical: 14, alignItems: "center" },
  resolved: { backgroundColor: "#3DDC84" },
  resolvedDisabled: { backgroundColor: "rgba(100, 100, 100, 0.6)" },
  resolvedDisabledText: { color: "rgba(15,25,45,0.5)" },
  cancel: { backgroundColor: "#FF1E1E" },
  bottomText: { color: "white", fontSize: 12, fontWeight: "900", letterSpacing: 0.5 },
  bottomTextDark: { color: "rgba(15,25,45,0.95)", fontSize: 12, fontWeight: "900", letterSpacing: 0.5 },

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
  modalBtnConfirm: {
    backgroundColor: "rgba(255, 80, 80, 0.15)",
    borderColor: "rgba(255, 80, 80, 0.4)",
  },
  modalBtnConfirmLoading: {
    backgroundColor: "rgba(255, 80, 80, 0.1)",
  },
  modalBtnConfirmText: {
    color: "rgba(255, 80, 80, 0.95)",
    fontSize: 12,
    fontWeight: "700",
  },
});