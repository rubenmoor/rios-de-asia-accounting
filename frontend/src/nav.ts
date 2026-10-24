import type { ComponentType } from "react";
import {
  BookingsIcon,
  ExpensesIcon,
  type IconProps,
  ImportIcon,
  RatesIcon,
  RecurringIcon,
  SettingsIcon,
  TimeIcon,
} from "./components/icons";

// The navigation entries of the app shell.
export const NAV: {
  path: string;
  label: string;
  icon: ComponentType<IconProps>;
}[] = [
  { path: "/bookings", label: "Bookings", icon: BookingsIcon },
  { path: "/expenses", label: "Expenses", icon: ExpensesIcon },
  { path: "/recurring", label: "Recurring", icon: RecurringIcon },
  { path: "/time", label: "Time", icon: TimeIcon },
  { path: "/rates", label: "Rates", icon: RatesIcon },
  { path: "/import", label: "Import", icon: ImportIcon },
  { path: "/settings", label: "Settings", icon: SettingsIcon },
];
