// What a single-node k3s cannot satisfy, and why ignoring it is not cheating.
//
// kube-prometheus-stack ships ServiceMonitors for a control plane made of
// separate processes with their own metrics ports. k3s runs the scheduler,
// controller-manager and kube-proxy inside one binary and exposes none of them,
// so those targets are permanently down on a local environment and their alerts
// permanently firing. Treating that as a platform failure would make the local
// run red forever, which is the fastest way to teach everyone to ignore it.
//
// Deliberately narrow: only control-plane components k3s subsumes. Anything
// else — a crashlooping Alertmanager, a Loki that stopped ingesting — still
// fails the run on local exactly as it would on a cloud.

const CONTROL_PLANE_ALERTS = ['KubeProxyDown', 'KubeControllerManagerDown', 'KubeSchedulerDown', 'KubeEtcdDown'];

// kubelet is deliberately absent: k3s does expose it, and a down kubelet target
// means node metrics are gone — which is a real failure anywhere.
const CONTROL_PLANE_JOBS = ['kube-proxy', 'kube-controller-manager', 'kube-scheduler', 'kube-etcd'];

const isControlPlaneAlert = (name) => CONTROL_PLANE_ALERTS.includes(name);

const isControlPlaneJob = (job) => CONTROL_PLANE_JOBS.some((j) => (job || '').includes(j));

module.exports = { CONTROL_PLANE_ALERTS, CONTROL_PLANE_JOBS, isControlPlaneAlert, isControlPlaneJob };
