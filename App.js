import React from "react";
import { NavigationContainer } from "@react-navigation/native";
import { createNativeStackNavigator } from "@react-navigation/native-stack";
import { StatusBar } from "expo-status-bar";

import LoginScreen from "./src/screens/LoginScreen";
import ForgotPasswordScreen from "./src/screens/ForgotPasswordScreen";
import CreateNewPasswordScreen from "./src/screens/CreateNewPasswordScreen";
import HomeScreen from "./src/screens/HomeScreen";
import RecordingScreen from "./src/screens/RecordingScreen";
import IncidentSummaryScreen from "./src/screens/IncidentSummaryScreen";
import MyIncidentScreen from "./src/screens/MyIncidentScreen";
import IncidentDetailsScreen from "./src/screens/IncidentDetailsScreen";
const Stack = createNativeStackNavigator();

export default function App() {
  return (
    <NavigationContainer>
      <StatusBar style="light" />
      <Stack.Navigator initialRouteName="Login" screenOptions={{ headerShown: false }}>
        <Stack.Screen name="Login" component={LoginScreen} />
        <Stack.Screen name="ForgotPassword" component={ForgotPasswordScreen} />
        <Stack.Screen name="CreateNewPassword" component={CreateNewPasswordScreen} />
        <Stack.Screen name="Home" component={HomeScreen} />
        <Stack.Screen name="Recording" component={RecordingScreen} />
        <Stack.Screen name="IncidentSummary" component={IncidentSummaryScreen} />
        <Stack.Screen name="MyIncident" component={MyIncidentScreen} />
        <Stack.Screen name="IncidentDetails" component={IncidentDetailsScreen} />
      </Stack.Navigator>
    </NavigationContainer>
  );
}
