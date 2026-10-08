// The only privileged operation in iRufus: obtaining a read/write descriptor
// for one raw disk node, through Apple's /usr/libexec/authopen and
// Authorization Services. No shell is involved, the argument vector is fixed,
// the path is validated, and no privilege persists once the descriptor is
// closed. See docs/SICUREZZA.md.

import Darwin
import Foundation
import Security

public enum BrokerError: Error, Sendable, Equatable {
    case invalidDevicePath(String)
    case authorizationDenied
    case authorizationFailed(OSStatus)
    case spawnFailed(Int32)
    case helperFailed(Int32)
    case noDescriptorReceived
    case identityMismatch(String)
}

public enum AccessMode: Sendable {
    case readOnly
    case readWrite

    var openFlags: Int32 {
        switch self {
        case .readOnly: O_RDONLY
        case .readWrite: O_RDWR
        }
    }

    var right: String {
        switch self {
        case .readOnly: "readonly"
        case .readWrite: "readwrite"
        }
    }
}

public enum PrivilegeBroker {
    static let authopenPath = "/usr/libexec/authopen"

    /// Accept only whole raw disk nodes: /dev/rdisk<N>.
    public static func validate(rawDevicePath path: String) throws {
        guard path.range(of: #"^/dev/rdisk[0-9]{1,4}$"#, options: .regularExpression) != nil else {
            throw BrokerError.invalidDevicePath(path)
        }
    }

    /// Open `identity`'s raw node and verify the descriptor refers to that disk.
    /// Blocks while the system shows the administrator authorization dialog.
    public static func openDevice(_ identity: DiskIdentity, mode: AccessMode, prompt: String) throws -> Int32 {
        let path = identity.rawDevicePath
        try validate(rawDevicePath: path)
        let fd = try authopen(path: path, mode: mode, prompt: prompt)
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw BrokerError.identityMismatch("fstat failed")
        }
        guard (st.st_mode & S_IFMT) == S_IFCHR else {
            close(fd)
            throw BrokerError.identityMismatch("not a character device")
        }
        guard let expected = identity.expectedRdev, st.st_rdev == expected else {
            close(fd)
            throw BrokerError.identityMismatch("device number \(st.st_rdev) does not match")
        }
        return fd
    }

    static func authopen(path: String, mode: AccessMode, prompt: String) throws -> Int32 {
        // 1. Obtain the right ourselves, so the dialog shows our explanation.
        let rightName = "sys.openfile.\(mode.right).\(path)"
        var authRef: AuthorizationRef?
        var status = AuthorizationCreate(nil, nil, [], &authRef)
        guard status == errAuthorizationSuccess, let authRef else { throw BrokerError.authorizationFailed(status) }
        defer { AuthorizationFree(authRef, [.destroyRights]) }

        status = rightName.withCString { rightPtr in
            prompt.withCString { promptPtr in
                kAuthorizationEnvironmentPrompt.withCString { envNamePtr in
                var item = AuthorizationItem(name: rightPtr, valueLength: 0, value: nil, flags: 0)
                var envItem = AuthorizationItem(name: envNamePtr, valueLength: strlen(promptPtr),
                                                value: UnsafeMutableRawPointer(mutating: promptPtr), flags: 0)
                return withUnsafeMutablePointer(to: &item) { itemPtr in
                    withUnsafeMutablePointer(to: &envItem) { envPtr in
                        var rights = AuthorizationRights(count: 1, items: itemPtr)
                        var env = AuthorizationEnvironment(count: 1, items: envPtr)
                        return AuthorizationCopyRights(authRef, &rights, &env, [.interactionAllowed, .extendRights, .preAuthorize], nil)
                    }
                }
                }
            }
        }
        if status == errAuthorizationCanceled || status == errAuthorizationDenied {
            throw BrokerError.authorizationDenied
        }
        guard status == errAuthorizationSuccess else { throw BrokerError.authorizationFailed(status) }
        var external = AuthorizationExternalForm()
        status = AuthorizationMakeExternalForm(authRef, &external)
        guard status == errAuthorizationSuccess else { throw BrokerError.authorizationFailed(status) }

        // 2. Socket pair: authopen's stdout carries the descriptor (SCM_RIGHTS).
        var sv: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0 else { throw BrokerError.spawnFailed(errno) }
        var stdinPipe: [Int32] = [-1, -1]
        guard pipe(&stdinPipe) == 0 else {
            close(sv[0]); close(sv[1])
            throw BrokerError.spawnFailed(errno)
        }
        defer {
            close(sv[0])
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, sv[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, stdinPipe[1])
        posix_spawn_file_actions_addclose(&actions, sv[0])

        // Fixed argument vector; the only variable element is the validated path.
        let args = [authopenPath, "-stdoutpipe", "-extauth", "-o", String(mode.openFlags), path]
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var env: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, authopenPath, &actions, nil, &cargs, &env)
        close(stdinPipe[0])
        close(sv[1])
        guard rc == 0 else {
            close(stdinPipe[1])
            throw BrokerError.spawnFailed(rc)
        }
        // 3. Hand over the authorization, then receive the descriptor.
        let wrote = withUnsafeBytes(of: &external) { raw in
            write(stdinPipe[1], raw.baseAddress, raw.count)
        }
        close(stdinPipe[1])
        let fd = wrote == MemoryLayout<AuthorizationExternalForm>.size ? receiveDescriptor(sv[0]) : nil
        var wstatus: Int32 = 0
        while waitpid(pid, &wstatus, 0) == -1 && errno == EINTR {}
        let exited = (wstatus & 0x7F) == 0
        let exitCode = (wstatus >> 8) & 0xFF
        guard exited && exitCode == 0 else {
            if let fd { close(fd) }
            throw exitCode == 0 ? BrokerError.helperFailed(-1) : BrokerError.helperFailed(exitCode)
        }
        guard let fd else { throw BrokerError.noDescriptorReceived }
        return fd
    }

    private static func receiveDescriptor(_ socket: Int32) -> Int32? {
        var dummy: UInt8 = 0
        let controlLen = Int(MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size + 8)
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlLen, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        memset(control, 0, controlLen)
        return withUnsafeMutablePointer(to: &dummy) { dummyPtr -> Int32? in
            var iov = iovec(iov_base: UnsafeMutableRawPointer(dummyPtr), iov_len: 1)
            return withUnsafeMutablePointer(to: &iov) { iovPtr -> Int32? in
                var msg = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovPtr, msg_iovlen: 1,
                                 msg_control: control, msg_controllen: socklen_t(controlLen), msg_flags: 0)
                var n: Int
                repeat { n = recvmsg(socket, &msg, 0) } while n < 0 && errno == EINTR
                guard n > 0, msg.msg_controllen >= socklen_t(MemoryLayout<cmsghdr>.size) else { return nil }
                let header = control.assumingMemoryBound(to: cmsghdr.self).pointee
                guard header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS else { return nil }
                // CMSG_DATA: header rounded up to 4-byte alignment on Darwin.
                let dataOffset = (MemoryLayout<cmsghdr>.size + 3) & ~3
                return control.load(fromByteOffset: dataOffset, as: Int32.self)
            }
        }
    }
}
